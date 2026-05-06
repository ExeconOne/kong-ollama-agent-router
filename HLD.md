# HLD: Kong Ollama Agent Router

## 1. Cel systemu

Projekt: **`kong-ollama-agent-router`**

Rozwiazanie sklada sie z dwoch klockow:

```text
1. ollama-node-router
   Istniejacy proces uruchamiany z CLI na tej samej maszynie, na ktorej dziala Ollama.
   Jest lokalnym agentem runtime: widzi maszyne, GPU, Ollama, zaladowane modele,
   kolejki, running counters i obciazenie.

2. kong-ollama-agent-router plugin
   Plugin do Kong API Gateway. Jest warstwa wejscia i decyzji routingowej.
   Ma logike `ollama-agent-router`: klasyfikuje request, wybiera model,
   decyduje sync/async/reject i wzbogaca odpowiedz o metadane routera.
   Po dane stricte zwiazane z fizyczna maszyna/GPU/Ollama siega do
   `ollama-node-router`.
```

Celem jest wyniesienie publicznego API do Kong Gateway bez duplikowania lokalnej logiki monitorowania maszyny w pluginie. Kong podejmuje decyzje routingu, ale nie odpala `nvidia-smi`, nie wykonuje `ollama ps`, nie trzyma lokalnego stanu GPU i nie zgaduje zajetosci modeli.

## 2. Zakres v1

### W zakresie

```text
- Kong plugin w Lua/OpenResty.
- Wykorzystanie istniejacego `ollama-node-router` jako lokalnego runtime agenta.
- OpenAI-compatible endpoint `POST /v1/chat/completions`.
- Heurystyczna klasyfikacja taskow.
- Ten sam routing/scoring co w `ollama-agent-router`.
- Pobieranie z `ollama-node-router`:
  - GPU/VRAM snapshot,
  - loaded models,
  - kolejki per model,
  - running counters,
  - status Ollama,
  - status jobow.
- Sync wykonanie requestu na wybranym modelu.
- Async przyjecie joba, jezeli `ollama-node-router` dostarcza job API.
- Health/status/models/gpu/metrics przez Kong jako facade nad pluginem i node-routerem.
```

### Poza zakresem v1

```text
- Osobny Redis jako wymagany element architektury.
- Osobny async worker jako trzeci klocek.
- Osobny monitor GPU/Ollama poza `ollama-node-router`.
- Streaming odpowiedzi.
- Modelowa klasyfikacja taskow jako domyslny tryb.
- Zarzadzanie pobieraniem modeli Ollama.
```

Redis, osobny worker albo zewnetrzny telemetry backend moga byc przyszlymi rozszerzeniami, ale nie sa czescia podstawowego HLD. W v1 calosc operacyjna ma pozostac dwuelementowa: Kong plugin + `ollama-node-router`.

## 3. Architektura wysokopoziomowa

```text
Client / Agent / App
        |
        v
Kong Gateway
        |
        v
kong-ollama-agent-router plugin
        |
        +--> Request validator
        +--> Task classifier
        +--> Routing engine
        +--> Node-router client
        +--> Response enricher
        |
        v
ollama-node-router
        |
        +--> Machine/GPU/Ollama telemetry
        +--> Loaded model state
        +--> Queue/running state
        +--> Optional job store
        +--> Optional execution proxy
        |
        v
Ollama Runtime
        |
        v
GPU / CPU
```

Najwazniejsza granica odpowiedzialnosci:

```text
Kong plugin:
  - rozumie request klienta,
  - klasyfikuje task,
  - wybiera model,
  - decyduje sync/async/reject,
  - pilnuje publicznego API, auth, rate limitow i odpowiedzi.

ollama-node-router:
  - dziala lokalnie przy Ollamie,
  - zna fizyczny stan maszyny,
  - zna stan GPU/VRAM,
  - zna modele zaladowane przez Ollama,
  - zna lokalne kolejki i running counters,
  - wykonuje lokalne operacje runtime, ktorych plugin Konga nie powinien wykonywac.
```

## 4. Komponenty

### 4.1. Kong plugin

Plugin jest implementowany zgodnie z fazami Konga:

```text
access:
  - walidacja body,
  - odczyt `router` metadata,
  - klasyfikacja requestu,
  - pobranie runtime snapshotu z `ollama-node-router`,
  - decyzja routingowa,
  - sync: proxy requestu do wybranego endpointu wykonawczego,
  - async: utworzenie joba w `ollama-node-router`,
  - reject: zwrot 4xx/5xx.

header_filter/body_filter:
  - dodanie `router` metadata do odpowiedzi sync,
  - opcjonalne naglowki diagnostyczne.

log:
  - metryki decyzji pluginu,
  - log strukturalny requestu,
  - korelacja z request id/job id.
```

Plugin nie pobiera danych sprzetowych bezposrednio. Nie odpala procesow systemowych, nie parsuje `nvidia-smi`, nie wywoluje `ollama ps` i nie utrzymuje globalnego stanu kolejek w pamieci workera Konga.

### 4.2. ollama-node-router jako runtime agent

`ollama-node-router` jest uruchamiany z CLI na maszynie z Ollama, np.:

```bash
ollama-agent-router serve --config /etc/ollama-agent-router/config.yaml
```

W tej architekturze jego podstawowa rola to **lokalny agent runtime**, a nie publiczna brama API. Dostarcza pluginowi Konga dane, ktorych Kong nie powinien pozyskiwac sam:

```text
- GPU provider, nazwa GPU, VRAM total/used/free, utilization,
- czy GPU snapshot jest swiezy,
- modele dostepne w Ollama,
- modele aktualnie zaladowane,
- czy model dziala na GPU/CPU/CPU+GPU,
- queue depth per model,
- running count per model,
- status jobow async,
- zdrowie lokalnej Ollamy.
```

`ollama-node-router` moze rowniez pozostac wykonawca requestow, ale bez podejmowania drugiej decyzji routingowej. Plugin przekazuje juz wybrany model. Node-router ma wtedy wykonac request na wskazanym modelu, zaktualizowac lokalne counters i zwrocic wynik.

### 4.3. Routing engine w pluginie

Routing engine jest portem logiki `ollama-agent-router` do Lua.

Wejscie:

```text
- request OpenAI-compatible,
- znormalizowane router metadata,
- klasyfikacja tasku,
- capabilities/config pobrane z `ollama-node-router`:
  - models,
  - routes,
  - router defaults,
  - queue policy,
  - GPU policy,
- runtime snapshot pobrany z `ollama-node-router`:
  - gpu,
  - loadedModels,
  - queueDepthByModel,
  - runningByModel.
```

Plugin nie powinien miec w swojej konfiguracji kopii `models`, `routes`, `gpu` ani `queue`, jezeli te dane sa juz konfigurowane w `ollama-node-router`. Plugin moze trzymac cache tych danych, ale zrodlem prawdy pozostaje node-router.

Wyjscie:

```text
sync:
  selected model, fallback models, score, decision reason

async:
  selected model, fallback models, score, queue position, decision reason

reject:
  HTTP status, reason
```

Reguly decyzyjne:

```text
1. Zbuduj kandydatow z preferredModels, routes[taskType], purpose i tags.
2. Usun forbiddenModels.
3. Odrzuc kandydatow niespelniajacych GPU-only lub concurrency policy.
4. Policz score:
   - priorytet trasy,
   - priorytet modelu,
   - dopasowanie purpose/tags,
   - preferredModels,
   - czy model jest juz zaladowany,
   - dopasowanie costClass do complexity,
   - dostepny VRAM,
   - queue depth,
   - running count,
   - exclusive model penalty.
5. Gdy klient wymusil async, utworz job przez `ollama-node-router`.
6. Gdy heavy load lub preferred model jest busy i allowAsync=true,
   utworz job przez `ollama-node-router`.
7. Gdy jest dostepny model, wykonaj sync na wybranym modelu.
8. Gdy tylko busy modele sa mozliwe i allowAsync=true, utworz job.
9. W innym przypadku zwroc 503.
```

### 4.4. Task classifier

Klasyfikator v1 jest deterministyczny i zgodny semantycznie z obecnym routerem Node:

```text
- code markers: typescript, javascript, node.js, python, function, class,
  stack trace, exception, compile, refactor, pull request, diff --git, ```
- tool markers: tool, function call, json schema, api call, webhook, bash, shell command
- reasoning markers: plan, architecture, design, debug, investigate, root cause, step by step
- summarize markers: summarize, summary, tl;dr, extract key points
- review markers: review, audit, risks, find bugs, code review
- fix markers: fix, bug, failing test, patch, regression
- generate markers: write, implement, create, generate, build
```

Jawne `router.taskType` inne niz `auto` ma pierwszenstwo przed klasyfikatorem.

## 5. Kontrakt plugin <-> ollama-node-router

Plugin potrzebuje stabilnego kontraktu HTTP do runtime agenta.

### 5.1. Capabilities/config snapshot

Plugin pobiera statyczno-polstatyczna konfiguracje routingu z node-routera:

```http
GET /v1/router/capabilities
```

Odpowiedz:

```json
{
  "nodeId": "gex44-a",
  "status": "ok",
  "version": "0.1.0",
  "router": {
    "defaultMode": "auto",
    "syncMaxQueueTimeMs": 250,
    "heavyLoadQueueDepth": 4,
    "heavyLoadGpuFreeMbThreshold": 2048,
    "defaultTaskType": "unknown",
    "classification": {
      "mode": "heuristic",
      "classifierTimeoutMs": 1500
    }
  },
  "gpu": {
    "requireGpuOnlyByDefault": true,
    "vramSafetyReserveMb": 1024
  },
  "queue": {
    "defaultPriority": "normal",
    "timeoutMs": 120000
  },
  "models": [
    {
      "name": "qwen2.5-coder:7b",
      "sizeGb": 4.7,
      "purpose": ["code_generate", "code_fix", "tool_use"],
      "priority": 20,
      "maxConcurrent": 2,
      "defaultContext": 4096,
      "maxContext": 8192,
      "timeoutMs": 180000,
      "costClass": "medium",
      "exclusive": false,
      "allowWhenBusy": true,
      "tags": ["code", "fast"]
    }
  ],
  "routes": {
    "code_generate": ["qwen2.5-coder:7b"],
    "code_fix": ["qwen2.5-coder:7b"],
    "tool_use": ["qwen2.5-coder:7b"]
  }
}
```

Plugin cache'uje capabilities dluzej niz runtime snapshot, np. 30-300 sekund. Jezeli capabilities nie da sie pobrac, node jest traktowany jako niedostepny dla nowych decyzji routingu, chyba ze plugin ma nadal swiezy cache z poprzedniego pobrania.

### 5.2. Runtime snapshot

Preferowany endpoint agregujacy:

```http
GET /v1/router/runtime
```

Odpowiedz:

```json
{
  "status": "ok",
  "timestamp": "2026-05-06T10:00:00.000Z",
  "ollama": {
    "baseUrl": "http://127.0.0.1:11434",
    "reachable": true
  },
  "gpu": {
    "provider": "nvidia",
    "name": "RTX 4000 SFF Ada",
    "vramTotalMb": 20480,
    "vramUsedMb": 12600,
    "vramFreeMb": 7880,
    "utilizationPct": 62,
    "snapshotAgeMs": 400
  },
  "loadedModels": [
    {
      "name": "qwen2.5-coder:7b",
      "size": "4.7 GB",
      "processor": "100% GPU",
      "until": "2026-05-06T10:30:00.000Z"
    }
  ],
  "queues": {
    "globalQueued": 2,
    "globalRunning": 1,
    "byModel": [
      {
        "model": "qwen2.5-coder:7b",
        "queued": 1,
        "running": 1,
        "concurrency": 2
      }
    ]
  },
  "jobs": {
    "queued": 2,
    "running": 1,
    "succeededRetained": 12,
    "failedRetained": 1
  }
}
```

Fallback do istniejacych endpointow:

```http
GET /health
GET /v1/router/status
GET /v1/router/models
GET /v1/router/gpu
GET /metrics
```

### 5.3. Sync execution

Plugin moze wykonac sync request na dwa sposoby.

Preferowany wariant:

```http
POST /v1/router/execute
```

Request:

```json
{
  "selectedModel": "deepseek-coder:6.7b",
  "request": {
    "model": "deepseek-coder:6.7b",
    "messages": [
      { "role": "user", "content": "Review this TypeScript function" }
    ],
    "temperature": 0.2,
    "stream": false
  },
  "routerDecision": {
    "taskType": "code_review",
    "score": 250,
    "reason": "Selected deepseek-coder:6.7b for code_review with score 250.0"
  }
}
```

`ollama-node-router` nie wybiera tu modelu ponownie. Jego zadaniem jest:

```text
- przyjac wybrany model,
- zwiekszyc running counter,
- wyslac request do Ollama,
- zmniejszyc running counter,
- zwrocic wynik i czasy wykonania.
```

Alternatywny wariant prostszy:

```text
Plugin proxyuje request bezposrednio do Ollama, a `ollama-node-router`
dostarcza tylko snapshoty telemetryczne. Wtedy plugin musi miec sposob
aktualizacji running counters albo zaakceptowac mniej dokladna zajetosc.
```

Dla parity z `ollama-agent-router` preferowany jest wariant przez `POST /v1/router/execute`.

### 5.4. Async jobs

Async powinien byc delegowany do `ollama-node-router`, bo to on ma lokalne kolejki i job store.

```http
POST /v1/router/jobs
GET  /v1/jobs/{jobId}
GET  /v1/jobs/{jobId}/result
DELETE /v1/jobs/{jobId}
```

Create job request:

```json
{
  "selectedModel": "gpt-oss:20b",
  "request": {
    "model": "gpt-oss:20b",
    "messages": [
      { "role": "user", "content": "Plan a multi-step debugging strategy" }
    ]
  },
  "classification": {
    "taskType": "agentic_reasoning",
    "complexity": "heavy"
  },
  "priority": "high",
  "routerDecision": {
    "score": 281,
    "reason": "Heavy load detected"
  }
}
```

Create job response:

```json
{
  "id": "job_gex44-a_01JABCDEF123",
  "status": "queued",
  "position": 3,
  "nodeId": "gex44-a",
  "selectedModel": "gpt-oss:20b"
}
```

Job id powinien zawierac `nodeId` albo odpowiedz musi zwracac `nodeId`, a publiczny job id budowany przez plugin musi byc deterministycznie routowalny do konkretnego node-routera. To usuwa potrzebe trzymania centralnej mapy job -> node w Kongu lub Redisie.

## 6. Publiczne API przez Kong

### 6.1. Chat completions

```http
POST /v1/chat/completions
```

Request:

```json
{
  "model": "auto",
  "messages": [
    { "role": "user", "content": "Review this TypeScript function" }
  ],
  "temperature": 0.2,
  "stream": false,
  "router": {
    "mode": "auto",
    "taskType": "auto",
    "priority": "normal",
    "allowAsync": true,
    "preferredModels": [],
    "forbiddenModels": [],
    "maxQueueTimeMs": 250,
    "maxExecutionTimeMs": 120000,
    "requireGpuOnly": true
  }
}
```

Sync response:

```json
{
  "id": "chatcmpl_x",
  "object": "chat.completion",
  "model": "deepseek-coder:6.7b",
  "choices": [],
  "router": {
    "mode": "sync",
    "taskType": "code_review",
    "selectedModel": "deepseek-coder:6.7b",
    "fallbackModels": ["qwen2.5-coder:7b"],
    "queueTimeMs": 4,
    "executionTimeMs": 1200,
    "decisionReason": "Selected deepseek-coder:6.7b for code_review with score 250.0"
  }
}
```

Async response:

```json
{
  "id": "job_gex44-a_01JABCDEF123",
  "object": "router.job",
  "status": "queued",
  "message": "Heavy load. Job accepted for asynchronous processing.",
  "router": {
    "mode": "async",
    "taskType": "agentic_reasoning",
    "nodeId": "gex44-a",
    "preferredModel": "gpt-oss:20b",
    "position": 3,
    "estimatedClass": "heavy"
  }
}
```

### 6.2. Job endpoints

Kong wystawia job endpoints jako facade. Dane i wyniki pochodza z `ollama-node-router`.

```http
GET    /v1/jobs
GET    /v1/jobs/{jobId}
GET    /v1/jobs/{jobId}/result
DELETE /v1/jobs/{jobId}
```

Statusy:

```text
queued
running
succeeded
failed
cancelled
expired
```

### 6.3. Status endpoints

```http
GET /health
GET /metrics
GET /v1/router/status
GET /v1/router/models
GET /v1/router/gpu
```

Te endpointy lacza:

```text
- stan pluginu Konga,
- ostatnia decyzje/metryki pluginu,
- runtime snapshot z `ollama-node-router`.
```

## 7. Konfiguracja pluginu

Plugin musi znac adres jednego lub wielu `ollama-node-router` agentow oraz polityki gatewayowe. Nie powinien duplikowac elementow, ktore sa juz konfigurowane na poziomie `ollama-node-router`, czyli:

```text
- models,
- routes,
- router defaults,
- queue limits,
- GPU/VRAM policy,
- job TTL/retry policy.
```

Te dane plugin pobiera z kazdego node-routera przez `GET /v1/router/capabilities`. Konfiguracja pluginu powinna opisywac tylko to, czego nie wie node-router:

```text
- lista node-routerow albo sposob discovery,
- timeouty polaczen z node-routerami,
- cache TTL dla capabilities/runtime,
- polityka wyboru node-routera przy wielu wezach,
- publiczne zachowanie gatewaya przy degraded/unavailable,
- opcjonalne per-consumer allow/deny i ekspozycja diagnostyki.
```

Przyklad:

```yaml
plugins:
  - name: kong-ollama-agent-router
    service: ollama-node-router
    config:
      node_routers:
        discovery: static
        nodes:
          - id: gex44-a
            base_url: http://10.0.10.11:11435
            weight: 100
            tags: [nvidia, gex44]
          - id: gex44-b
            base_url: http://10.0.10.12:11435
            weight: 100
            tags: [nvidia, gex44]
        capabilities_path: /v1/router/capabilities
        runtime_path: /v1/router/runtime
        execute_path: /v1/router/execute
        create_job_path: /v1/router/jobs
        request_timeout_ms: 120000
        snapshot_timeout_ms: 500
        capabilities_cache_ttl_ms: 60000
        runtime_cache_ttl_ms: 1000
        stale_snapshot_ttl_ms: 5000
        allow_degraded_snapshot: false

      selection:
        strategy: score
        prefer_loaded_model: true
        respect_node_weight: true
        failover_on_execute_error: true
        max_failover_attempts: 1

      gateway_policy:
        expose_diagnostics: false
        allow_client_preferred_models: true
        allow_client_forbidden_models: true
        default_error_status: 503
```

## 8. Wiele ollama-node-routerow

Plugin moze obslugiwac wiele instancji `ollama-node-router`. Kazda instancja reprezentuje jedna fizyczna maszyne albo jeden lokalny runtime Ollama. Plugin traktuje je jako osobne wezly decyzyjne, nie jako zwykly upstream round-robin.

### 8.1. Discovery

W v1 preferowane jest statyczne discovery w konfiguracji pluginu:

```text
- id,
- base_url,
- weight,
- tags.
```

Przyszle rozszerzenia:

```text
- DNS SRV,
- Kong upstream/service targets,
- Kubernetes service discovery,
- plik generowany przez inventory.
```

### 8.2. Pobieranie danych

Plugin okresowo albo per-request pobiera z kazdego node-routera:

```text
GET /v1/router/capabilities
GET /v1/router/runtime
```

Zasady:

```text
- capabilities cache jest dluzszy, bo modele/routes zmieniaja sie rzadko,
- runtime cache jest krotki, bo queue/GPU/running zmieniaja sie szybko,
- pobieranie snapshotow powinno isc rownolegle z krotkim timeoutem,
- node bez swiezego runtime snapshotu nie bierze udzialu w decyzji,
  chyba ze wlaczono degraded fallback,
- node bez capabilities nie bierze udzialu w decyzji nowych requestow.
```

### 8.3. Model wyboru node + model

Routing engine nie wybiera samego modelu. Wybiera pare:

```text
RouteTarget = {
  nodeId: string;
  nodeBaseUrl: string;
  model: ModelSpec;
  capabilities: NodeCapabilities;
  runtime: RuntimeSnapshot;
}
```

Kandydaci sa budowani per node:

```text
1. Dla kazdego zdrowego node-routera wez jego capabilities.
2. Zbuduj kandydatow z routes[taskType], purpose, tags i preferredModels
   w ramach tego node-routera.
3. Dolacz runtime tego node-routera: GPU, loadedModels, queues, running.
4. Policz score dla pary node+model.
5. Wybierz najwyzej oceniona pare.
```

Jezeli dwa node-routery maja ten sam model, np. `qwen2.5-coder:7b`, to sa to dwa rozne kandydaty:

```text
gex44-a / qwen2.5-coder:7b
gex44-b / qwen2.5-coder:7b
```

Moga dostac rozny score, bo roznia sie:

```text
- wolnym VRAM,
- loaded model state,
- queue depth,
- running count,
- node weight,
- snapshot freshness,
- statusem Ollama,
- tagami node'a.
```

### 8.4. Preferred/forbidden models

`router.preferredModels` i `router.forbiddenModels` domyslnie odnosza sie do nazw modeli, nie do wezlow.

Opcjonalnie plugin moze wspierac kwalifikowana forme:

```text
gex44-a/qwen2.5-coder:7b
gex44-b/gpt-oss:20b
```

Ta forma pozwala klientowi zasugerowac konkretny node, ale nie moze omijac polityk:

```text
- forbiddenModels,
- allowlist consumer/group,
- GPU-only,
- busy/exclusive,
- health node-routera.
```

### 8.5. Sync execution

Po wyborze pary `nodeId + model` plugin wysyla sync request tylko do wybranego node-routera:

```text
POST {node.base_url}/v1/router/execute
```

`selectedModel` jest nazwa modelu z capabilities tego node'a. Node-router wykonuje request lokalnie w swojej Ollamie.

Failover:

```text
- jezeli execute nie zostal wyslany albo zakonczyl sie bledem polaczenia,
  plugin moze przeliczyc routing i sprobowac kolejnego kandydata,
- failover sync powinien miec niski limit prob, np. 1,
- po rozpoczeciu streamingu failover nie jest wspierany w v1,
- jezeli node-router zwrocil blad wykonania z Ollama, plugin domyslnie zwraca blad,
  a retry wymaga jawnej polityki.
```

### 8.6. Async jobs

Async job jest tworzony na konkretnym node-routerze:

```text
POST {node.base_url}/v1/router/jobs
```

Publiczny job id musi pozwalac odtworzyc docelowy node:

```text
job_gex44-a_01JABCDEF123
```

Dzieki temu wiele instancji Konga nie potrzebuje wspolnej mapy jobow. `GET /v1/jobs/{jobId}` i `GET /v1/jobs/{jobId}/result` parsuje `nodeId` z job id i proxyuje request do wlasciwego `ollama-node-router`.

Failover async:

```text
- jezeli create job nie powiedzie sie przed utworzeniem joba, plugin moze sprobowac
  kolejnego kandydata,
- jezeli job zostal utworzony, dalszy status nalezy do tego node-routera,
- migracja joba miedzy node-routerami nie jest w zakresie v1.
```

### 8.7. Spojnosc konfiguracji

Kazdy `ollama-node-router` moze miec inna konfiguracje modeli i tras. Plugin nie wymaga identycznego configu na wszystkich wezach.

Praktyczne zasady:

```text
- jezeli node ma model tylko dla code_review, kandydaci z tego node'a pojawia sie
  tylko dla tras, ktore on deklaruje,
- jezeli kilka node'ow deklaruje ten sam model, score wybiera najlepszy runtime,
- jezeli node ma stara konfiguracje, capabilities version/config hash powinny to pokazac,
- status endpoint Konga powinien pokazac capabilities per node, zeby operator widzial
  rozjazdy konfiguracji.
```

## 9. Przeplywy

### 9.1. Sync request

```text
1. Klient wysyla POST /v1/chat/completions do Konga.
2. Kong uruchamia `kong-ollama-agent-router` w fazie access.
3. Plugin waliduje body i odrzuca stream=true w v1.
4. Plugin normalizuje router metadata.
5. Plugin klasyfikuje zadanie albo respektuje jawny taskType.
6. Plugin pobiera capabilities/runtime z jednego lub wielu `ollama-node-router`.
7. Routing engine wybiera pare nodeId + model.
8. Plugin wysyla request do wybranego `ollama-node-router` z `selectedModel`.
9. `ollama-node-router` wykonuje request w Ollama i aktualizuje lokalne counters.
10. Plugin dodaje obiekt `router` do odpowiedzi.
11. Kong zwraca klientowi OpenAI-compatible response.
```

### 9.2. Async request

```text
1. Klient wysyla request z router.allowAsync=true albo router.mode=async.
2. Plugin pobiera capabilities/runtime z jednego lub wielu `ollama-node-router`.
3. Plugin podejmuje decyzje async i wybiera pare nodeId + model.
4. Plugin wywoluje `POST /v1/router/jobs` na wybranym `ollama-node-router`.
5. `ollama-node-router` zapisuje job w swoim job store i dodaje go do lokalnej kolejki.
6. Plugin zwraca 202 i `router.job` z job id zawierajacym nodeId.
7. Klient odpytuje job endpoint przez Konga.
8. Kong odtwarza nodeId z job id i proxyuje status/result do wlasciwego `ollama-node-router`.
```

### 9.3. Heavy load

Heavy load jest liczony w pluginie per node-router na podstawie jego runtime snapshotu:

```text
- global queue depth >= router.heavy_load_queue_depth,
- GPU free MB < router.heavy_load_gpu_free_mb_threshold,
- preferred model jest busy,
- exclusive model juz wykonuje zadanie,
- model wymaga wiecej VRAM niz dostepne i nie jest zaladowany,
- snapshot GPU jest zbyt stary i policy nie pozwala na degraded mode.
```

Policy:

```text
allowAsync=true, mode!=sync  -> 202 async job przez `ollama-node-router`
allowAsync=false             -> 503
mode=sync                    -> sync tylko gdy jest dostepny model, inaczej 503
mode=async                   -> zawsze kolejkuj, jezeli jest kandydat i wybrany node-router jest zdrowy
```

## 10. Dane i typy

### 10.1. Router metadata

```ts
type RouterRequestMetadata = {
  mode?: "auto" | "sync" | "async";
  allowAsync?: boolean;
  taskType?: TaskType | "auto";
  priority?: "low" | "normal" | "high";
  preferredModels?: string[];
  forbiddenModels?: string[];
  maxQueueTimeMs?: number;
  maxExecutionTimeMs?: number;
  requireGpuOnly?: boolean;
};
```

### 10.2. Node capabilities

```ts
type NodeCapabilities = {
  nodeId: string;
  status: "ok" | "degraded" | "unavailable";
  version: string;
  router: {
    defaultMode: "auto" | "sync" | "async";
    syncMaxQueueTimeMs: number;
    heavyLoadQueueDepth: number;
    heavyLoadGpuFreeMbThreshold: number;
    defaultTaskType: TaskType;
  };
  gpu: {
    requireGpuOnlyByDefault: boolean;
    vramSafetyReserveMb: number;
  };
  queue: {
    defaultPriority: "low" | "normal" | "high";
    timeoutMs: number;
  };
  models: ModelSpec[];
  routes: Partial<Record<TaskType | string, string[]>>;
};
```

### 10.3. Runtime snapshot

```ts
type RuntimeSnapshot = {
  status: "ok" | "degraded" | "unavailable";
  timestamp: string;
  ollama: {
    baseUrl: string;
    reachable: boolean;
  };
  gpu?: {
    provider: "none" | "nvidia";
    name?: string;
    vramTotalMb: number;
    vramUsedMb: number;
    vramFreeMb: number;
    utilizationPct: number;
    snapshotAgeMs: number;
  };
  loadedModels: LoadedModel[];
  queues: {
    globalQueued: number;
    globalRunning: number;
    byModel: Array<{
      model: string;
      queued: number;
      running: number;
      concurrency: number;
    }>;
  };
};
```

### 10.4. Route target

```ts
type RouteTarget = {
  nodeId: string;
  nodeBaseUrl: string;
  nodeWeight: number;
  model: ModelSpec;
  capabilities: NodeCapabilities;
  runtime: RuntimeSnapshot;
};
```

### 10.5. Model spec

```ts
type ModelSpec = {
  name: string;
  sizeGb: number;
  purpose: string[];
  priority: number;
  maxConcurrent: number;
  defaultContext: number;
  maxContext: number;
  timeoutMs: number;
  costClass: "low" | "medium" | "high";
  exclusive: boolean;
  allowWhenBusy: boolean;
  tags: string[];
};
```

## 11. Deployment

### 11.1. Lokalna maszyna z Ollama

Na maszynie z GPU/Ollama:

```text
ollama
ollama-node-router
```

`ollama-node-router` powinien byc wystawiony tylko dla Konga albo przez prywatna siec/VPN. Nie jest publicznym API dla klientow koncowych w tej architekturze.

### 11.2. Kong

Na warstwie gateway:

```text
kong-gateway
kong-ollama-agent-router plugin
```

Kong moze dzialac na tej samej maszynie, na innym hoscie, w Dockerze albo w Kubernetes. W kazdym wariancie musi miec sieciowy dostep do `ollama-node-router`.

### 11.3. Minimalna topologia

```text
client
  -> kong-gateway + kong-ollama-agent-router plugin
  -> ollama-node-router
  -> ollama
  -> GPU/CPU
```

Nie ma wymaganego `redis`, `worker`, `monitor` ani dodatkowego sidecara.

## 12. Bezpieczenstwo

```text
- Publiczne API wystawia Kong, nie `ollama-node-router`.
- `ollama-node-router` powinien byc dostepny tylko z Konga.
- Plugin nie loguje pelnego promptu domyslnie.
- Job endpoints przez Kong przechodza przez te same mechanizmy auth co chat endpoint.
- Pole `router.preferredModels` nie moze omijac forbiddenModels, allowlist ani GPU-only.
- Snapshoty runtime nie powinny ujawniac klientom danych hosta, jezeli endpoint nie jest admin-only.
- Naglowki diagnostyczne domyslnie wylaczone.
```

## 13. Observability

Metryki pluginu:

```text
- decisions_total{type,task_type,model}
- request_duration_ms{mode,task_type,model}
- node_router_snapshot_duration_ms
- node_router_execute_duration_ms{model}
- routing_rejects_total{reason}
```

Metryki runtime z `ollama-node-router`:

```text
- queue_depth{model}
- running{model}
- jobs_total{status,model}
- gpu_vram_free_mb
- gpu_utilization_pct
- ollama_reachable
```

Logi strukturalne pluginu:

```text
- request id,
- consumer id,
- task type,
- selected model,
- decision type,
- decision reason,
- score,
- node-router status,
- queue time,
- execution time,
- status code.
```

## 14. Bledy i degradacja

```text
ollama-node-router unavailable:
  - plugin nie ma wiarygodnego snapshotu maszyny,
  - sync/async powinny zwrocic 503,
  - mozliwy jest tylko jawnie skonfigurowany degraded fallback,
    jezeli operator zaakceptuje routing bez danych GPU.

GPU snapshot stale/missing:
  - jezeli allow_degraded_snapshot=true, plugin moze uzyc ostatniego snapshotu
    albo statycznych limitow,
  - jezeli requireGpuOnly=true i brak pewnych danych, odrzuc modele wymagajace GPU.

Ollama unavailable wedlug node-routera:
  - plugin zwraca 503 przed proba wykonania requestu,
  - status endpoint pokazuje degraded/unavailable.

Execute timeout:
  - plugin zwraca blad upstream,
  - `ollama-node-router` odpowiada za cleanup lokalnych running counters.

Loaded models snapshot stale:
  - nie przyznawaj bonusu za loaded,
  - dalej mozna route'owac wedlug model spec i VRAM policy tylko w degraded mode.
```

## 15. Struktura repo

Proponowana struktura:

```text
kong-ollama-agent-router/
  README.md
  HLD.md
  kong-plugin/
    kong/
      plugins/
        kong-ollama-agent-router/
          handler.lua
          schema.lua
          access.lua
          classifier.lua
          router_engine.lua
          node_router_client.lua
          response.lua
          metrics.lua
  spec/
    fixtures/
    unit/
    integration/
  examples/
    kong.yml
    docker-compose.yml
    kubernetes/
```

Zmiany po stronie `ollama-node-router`, jezeli beda potrzebne do kontraktu:

```text
ollama-node-router/
  src/server.ts
    - GET /v1/router/capabilities
    - GET /v1/router/runtime
    - POST /v1/router/execute
    - POST /v1/router/jobs
```

## 16. Plan implementacji

### Etap 1: Kontrakt runtime agenta

```text
- doprecyzowac endpointy `ollama-node-router` wymagane przez plugin,
- dodac `GET /v1/router/capabilities`, jezeli publiczny snapshot configu nie istnieje,
- dodac `GET /v1/router/runtime`, jezeli agregat nie istnieje,
- dodac `POST /v1/router/execute`, jezeli plugin ma wykonywac sync przez node-router,
- przygotowac fixtures capabilities i runtime snapshot.
```

### Etap 2: Szkielet pluginu

```text
- schema.lua z konfiguracja node_routers, cache, timeoutow i gateway policy,
- node_router_client.lua,
- request validation,
- status/health facade.
```

### Etap 3: Parity routingu

```text
- port klasyfikatora,
- port scoringu,
- parity fixtures z `ollama-agent-router`,
- testy decyzji sync/async/reject na capabilities + runtime snapshotach,
- testy wyboru nodeId + model dla wielu node-routerow.
```

### Etap 4: Sync i async

```text
- sync przez `POST /v1/router/execute`,
- async przez `POST /v1/router/jobs`,
- proxy job endpoints przez Konga,
- wzbogacanie odpowiedzi o `router`.
```

### Etap 5: Packaging

```text
- Docker image z Kongiem i pluginem,
- LuaRocks package albo custom plugin bundle,
- docker-compose: kong + ollama-node-router + ollama,
- Kubernetes example z KongPlugin i prywatnym Service do node-routera.
```

## 17. Kryteria akceptacji

```text
1. Rozwiazanie sklada sie operacyjnie z dwoch klockow:
   `kong-ollama-agent-router` plugin i `ollama-node-router`.
2. Plugin nie pobiera bezposrednio danych GPU/Ollama z maszyny.
3. Plugin podejmuje decyzje routingu na podstawie konfiguracji i snapshotu
   z `ollama-node-router`.
4. Ten sam request i ta sama konfiguracja daja zgodna decyzje routingu
   jak `ollama-agent-router` dla zestawu parity fixtures.
5. Sync request trafia do modelu wybranego przez plugin i zwraca response
   z obiektem `router`.
6. Async request zwraca 202 z job id, a job jest utrzymywany przez
   `ollama-node-router`.
7. Busy exclusive model przechodzi do async albo 503 zgodnie z policy.
8. GPU-only nie kieruje requestu do modelu dzialajacego na CPU.
9. Niedostepnosc `ollama-node-router` skutkuje kontrolowanym degraded/503.
10. `/metrics` pokazuje decyzje pluginu oraz runtime state z node-routera.
```

## 18. Najwazniejsze decyzje projektowe

```text
1. Jedynym lokalnym agentem przy Ollamie jest istniejacy `ollama-node-router`.
2. Kong plugin zawiera logike `ollama-agent-router`, ale nie zbiera danych
   sprzetowych samodzielnie.
3. Dane fizyczne maszyny, GPU, loaded models, queue depth i running counters
   pochodza z `ollama-node-router`.
4. Async job store i lokalne kolejki naleza do `ollama-node-router`.
5. Redis/worker/monitor nie sa podstawowymi klockami v1.
6. Streaming jest swiadomie odlozony poza v1.
```
