# --- nomad workload identity ---

resource "consul_acl_auth_method" "nomad_workloads" {
  name         = "nomad-workloads"
  type         = "jwt"
  display_name = "Nomad workloads"
  description  = "Nomad workload identities"

  # No MaxTokenTTL: Nomad cannot recreate a Consul token that expired.
  config_json = jsonencode({
    JWKSURL          = local.nomad_jwks_url
    JWKSCACert       = local.ca_cert
    JWTSupportedAlgs = ["RS256"]
    BoundAudiences   = ["consul.io"]
    ClaimMappings = {
      nomad_namespace = "nomad_namespace"
      nomad_job_id    = "nomad_job_id"
      nomad_task      = "nomad_task"
      nomad_service   = "nomad_service"
    }
  })
}

resource "consul_acl_binding_rule" "nomad_services" {
  auth_method = consul_acl_auth_method.nomad_workloads.name
  description = "Nomad services register themselves"
  selector    = "\"nomad_service\" in value"
  bind_type   = "service"
  bind_name   = "$${value.nomad_service}"
}

resource "consul_acl_binding_rule" "nomad_tasks" {
  auth_method = consul_acl_auth_method.nomad_workloads.name
  description = "Nomad tasks read the catalog in templates"
  selector    = "\"nomad_service\" not in value"
  bind_type   = "role"
  bind_name   = consul_acl_role.nomad_tasks.name
}

# One role for every namespace, because every task needs the same catalog
# access and Consul CE has no namespaces to split it by.
resource "consul_acl_role" "nomad_tasks" {
  name        = "nomad-tasks"
  description = "Tasks with a Nomad workload identity"
  policies    = [consul_acl_policy.nomad_tasks.id]
}

resource "consul_acl_policy" "nomad_tasks" {
  name        = "nomad-tasks"
  description = "Read services and nodes for template blocks"

  rules = <<-EOT
    service_prefix "" {
      policy = "read"
    }

    node_prefix "" {
      policy = "read"
    }
  EOT
}

# --- agents ---

# The Nomad agent is server and client in one, so this is the union of
# Nomad's server and client policies. Consul's own agent token uses the
# homelab-1 node identity and needs no policy.
resource "consul_acl_policy" "nomad_agent" {
  name        = "nomad-agent"
  description = "Nomad server and client agent"

  rules = <<-EOT
    agent_prefix "" {
      policy = "read"
    }

    node_prefix "" {
      policy = "write"
    }

    service_prefix "" {
      policy = "write"
    }

    acl  = "write"
    mesh = "write"
  EOT
}

# Agent metrics now; service and node reads for consul_sd_configs in phase 3.
resource "consul_acl_policy" "prometheus" {
  name        = "prometheus"
  description = "Prometheus metrics and service discovery"

  rules = <<-EOT
    agent_prefix "" {
      policy = "read"
    }

    service_prefix "" {
      policy = "read"
    }

    node_prefix "" {
      policy = "read"
    }
  EOT
}
