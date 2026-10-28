locals {
  ca_cert = file(pathexpand("~/.homelab/pki/ca.crt"))

  # Vault and Consul fetch Nomad's workload identity signing keys from here.
  nomad_jwks_url = "https://192.168.86.199:4646/.well-known/jwks.json"

  nomad_namespaces = {
    ingress       = "Traefik"
    media         = "Jellyfin and the media apps"
    torrents      = "Gluetun and qBittorrent"
    data          = "Shared Postgres"
    tabletop      = "Tabletop"
    bitwarden     = "Vaultwarden"
    arcto         = "Arcto Vaultwarden"
    home          = "Home Assistant and Piper"
    observability = "Metrics, logs and traces"
    ops           = "Backups and maintenance"
  }
}

resource "nomad_namespace" "this" {
  for_each = local.nomad_namespaces

  name        = each.key
  description = each.value
}

# Diun reads every job's images with its workload identity, so it needs no
# long-lived token.
resource "nomad_acl_policy" "diun" {
  name        = "diun"
  description = "Read jobs in every namespace"

  rules_hcl = <<-EOT
    namespace "*" {
      capabilities = ["list-jobs", "read-job"]
    }
  EOT

  job_acl {
    namespace = "ops"
    job_id    = "diun"
  }
}

# Tasks reserve their usual memory and may burst to memory_max, which needs
# oversubscription. The other values are Nomad's defaults, which the resource
# would otherwise reset.
resource "nomad_scheduler_config" "this" {
  scheduler_algorithm             = "binpack"
  memory_oversubscription_enabled = true

  preemption_config = {
    system_scheduler_enabled   = true
    sysbatch_scheduler_enabled = true
    batch_scheduler_enabled    = false
    service_scheduler_enabled  = false
  }
}
