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
