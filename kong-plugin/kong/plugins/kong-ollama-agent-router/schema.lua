return {
  name = "kong-ollama-agent-router",
  fields = {
    {
      config = {
        type = "record",
        fields = {
          {
            node_routers = {
              type = "record",
              required = true,
              fields = {
                { discovery = { type = "string", default = "static", one_of = { "static" } } },
                {
                  nodes = {
                    type = "array",
                    required = true,
                    len_min = 1,
                    elements = {
                      type = "record",
                      fields = {
                        { id = { type = "string", required = true, match = "^[A-Za-z0-9.-]+$" } },
                        { base_url = { type = "string", required = true } },
                        { weight = { type = "number", default = 0 } },
                        { tags = { type = "array", elements = { type = "string" }, default = {} } },
                        {
                          auth = {
                            type = "record",
                            required = false,
                            fields = {
                              { type = { type = "string", default = "none", one_of = { "none", "bearer", "header" } } },
                              { token = { type = "string", required = false } },
                              { header_name = { type = "string", default = "x-api-key" } },
                              { header_prefix = { type = "string", required = false } },
                            },
                          },
                        },
                        {
                          tls = {
                            type = "record",
                            required = false,
                            fields = {
                              { verify = { type = "boolean", default = true } },
                              { server_name = { type = "string", required = false } },
                              {
                                client_cert = {
                                  type = "record",
                                  required = false,
                                  fields = {
                                    { enabled = { type = "boolean", default = false } },
                                    { cert_path = { type = "string", required = false } },
                                    { key_path = { type = "string", required = false } },
                                  },
                                },
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                },
                {
                  security = {
                    type = "record",
                    required = false,
                    fields = {
                      {
                        auth = {
                          type = "record",
                          required = false,
                          fields = {
                            { type = { type = "string", default = "none", one_of = { "none", "bearer", "header" } } },
                            { token = { type = "string", required = false } },
                            { header_name = { type = "string", default = "x-api-key" } },
                            { header_prefix = { type = "string", required = false } },
                          },
                        },
                      },
                      {
                        tls = {
                          type = "record",
                          required = false,
                          fields = {
                            { verify = { type = "boolean", default = true } },
                            { server_name = { type = "string", required = false } },
                            {
                              client_cert = {
                                type = "record",
                                required = false,
                                fields = {
                                  { enabled = { type = "boolean", default = false } },
                                  { cert_path = { type = "string", required = false } },
                                  { key_path = { type = "string", required = false } },
                                },
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                },
                { capabilities_path = { type = "string", default = "/v1/router/capabilities" } },
                { runtime_path = { type = "string", default = "/v1/router/runtime" } },
                { execute_path = { type = "string", default = "/v1/router/execute" } },
                { create_job_path = { type = "string", default = "/v1/router/jobs" } },
                { request_timeout_ms = { type = "integer", default = 120000, between = { 1, 3600000 } } },
                { snapshot_timeout_ms = { type = "integer", default = 500, between = { 1, 60000 } } },
                { capabilities_cache_ttl_ms = { type = "integer", default = 60000, between = { 0, 3600000 } } },
                { runtime_cache_ttl_ms = { type = "integer", default = 1000, between = { 0, 60000 } } },
                { stale_snapshot_ttl_ms = { type = "integer", default = 5000, between = { 0, 600000 } } },
                { allow_degraded_snapshot = { type = "boolean", default = false } },
              },
            },
          },
          {
            selection = {
              type = "record",
              required = false,
              fields = {
                { strategy = { type = "string", default = "score", one_of = { "score" } } },
                { prefer_loaded_model = { type = "boolean", default = true } },
                { respect_node_weight = { type = "boolean", default = true } },
                { failover_on_execute_error = { type = "boolean", default = true } },
                { max_failover_attempts = { type = "integer", default = 1, between = { 0, 10 } } },
              },
            },
          },
          {
            gateway_policy = {
              type = "record",
              required = false,
              fields = {
                { expose_diagnostics = { type = "boolean", default = false } },
                { allow_client_preferred_models = { type = "boolean", default = true } },
                { allow_client_forbidden_models = { type = "boolean", default = true } },
                { default_error_status = { type = "integer", default = 503, between = { 400, 599 } } },
              },
            },
          },
        },
      },
    },
  },
}
