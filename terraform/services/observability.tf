locals {
  public_services = {
    bitwarden = {
      display_name = "Bitwarden"
      url          = format("https://bitwarden.%s", var.domain)
    }
    jellyfin = {
      display_name = "Jellyfin"
      url          = format("https://jellyfin.%s", var.domain)
    }
    seerr = {
      display_name = "Seerr"
      url          = format("https://seerr.%s", var.domain)
    }
    tabletop = {
      display_name = "Tabletop"
      url          = format("https://tabletop.%s/health", var.domain)
    }
  }
}

# --- collectors ---

module "alloy" {
  source = "../modules/service"

  name      = "alloy"
  namespace = "observability"
  image     = "grafana/alloy:latest"

  job_file = format("%s/jobs/observability/alloy.nomad.hcl", path.module)
  job_vars = {
    user   = format("%s:%s", var.uid, var.gid)
    config = file(format("%s/config/alloy.alloy", path.module))
  }
  env = local.shared_env

  domain = var.domain
}

module "blackbox_exporter" {
  source = "../modules/service"

  name      = "blackbox-exporter"
  namespace = "observability"
  image     = "prom/blackbox-exporter:latest"

  job_file = format("%s/jobs/observability/blackbox-exporter.nomad.hcl", path.module)
  job_vars = {
    config = file(format("%s/config/blackbox.yml", path.module))
  }
  env = local.shared_env

  domain = var.domain
}

locals {
  # Relative, so a plan from another checkout or worktree does not rebuild the image.
  observability_agent_context = format("%s/../../observability", path.module)
  observability_agent_source_hash = sha256(join("", [
    for source_path in sort(concat(["Dockerfile", "go.mod"], tolist(fileset(local.observability_agent_context, "**/*.go")))) :
    format("%s:%s", source_path, filesha256(format("%s/%s", local.observability_agent_context, source_path)))
  ]))
  observability_agent_image_tag = substr(local.observability_agent_source_hash, 0, 12)
}

module "observability_agent" {
  source = "../modules/service"

  name      = "observability-agent"
  namespace = "observability"
  image     = format("observability-agent:%s", local.observability_agent_image_tag)

  # No revision label: it would rebuild the image on every commit to this
  # repository, not only when the agent's source changes.
  build = {
    context = local.observability_agent_context
    labels = {
      "org.opencontainers.image.source"  = "https://github.com/Reilley64/homelab"
      "org.opencontainers.image.version" = local.observability_agent_image_tag
    }
  }

  job_file = format("%s/jobs/observability/observability-agent.nomad.hcl", path.module)
  env      = local.shared_env

  domain = var.domain
}

# --- storage ---

module "loki" {
  source = "../modules/service"

  name      = "loki"
  namespace = "observability"
  image     = "grafana/loki:latest"

  job_file = format("%s/jobs/observability/loki.nomad.hcl", path.module)
  job_vars = {
    user   = format("%s:%s", var.uid, var.gid)
    config = file(format("%s/config/loki.yml", path.module))
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

module "prometheus" {
  source = "../modules/service"

  name      = "prometheus"
  namespace = "observability"
  image     = "prom/prometheus:latest"

  job_file = format("%s/jobs/observability/prometheus.nomad.hcl", path.module)
  job_vars = {
    user      = format("%s:%s", var.uid, var.gid)
    consul_ca = file(pathexpand("~/.homelab/pki/ca.crt"))
    config = templatefile(format("%s/config/prometheus.yml.tftpl", path.module), {
      public_services = local.public_services
    })
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

module "tempo" {
  source = "../modules/service"

  name      = "tempo"
  namespace = "observability"
  image     = "grafana/tempo:latest"

  job_file = format("%s/jobs/observability/tempo.nomad.hcl", path.module)
  job_vars = {
    user   = format("%s:%s", var.uid, var.gid)
    config = file(format("%s/config/tempo.yml", path.module))
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

# --- grafana ---

module "grafana" {
  source = "../modules/service"

  name      = "grafana"
  namespace = "observability"
  image     = "grafana/grafana:latest"

  job_file = format("%s/jobs/observability/grafana.nomad.hcl", path.module)
  job_vars = {
    user = format("%s:%s", var.uid, var.gid)
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

module "mcp_grafana" {
  source = "../modules/service"

  name      = "mcp-grafana"
  namespace = "observability"
  image     = "grafana/mcp-grafana:latest"

  job_file = format("%s/jobs/observability/mcp-grafana.nomad.hcl", path.module)
  env      = local.shared_env

  domain  = var.domain
  traefik = true
}

resource "random_password" "mcp_grafana_caller_token" {
  length  = 48
  special = false
}

# Both are read once to write kv/observability/mcp-grafana in Vault.
output "mcp_grafana_caller_token" {
  value     = random_password.mcp_grafana_caller_token.result
  sensitive = true
}

output "mcp_grafana_service_account_token" {
  value     = grafana_service_account_token.mcp_grafana.key
  sensitive = true
}
