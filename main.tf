provider "docker" {
  host = "ssh://${var.username}@192.168.86.199"
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "grafana" {
  url  = "http://grafana.localdomain"
  auth = "admin:${var.password}"
}

provider "unifi" {
  api_url = "https://192.168.86.1"
  api_key = var.unifi_api_key

  allow_insecure = true
}

locals {
  shared_env = [
    "TZ=Australia/Melbourne",
    "PGID=${var.gid}",
    "PUID=${var.uid}",
  ]
}

resource "docker_image" "alpine" {
  name         = "alpine:latest"
  keep_locally = false
}

module "diun" {
  source = "./modules/service"

  domain = var.domain
  name   = "diun"
  image  = "crazymax/diun:4.30.0"

  env = concat(local.shared_env, [
    "DIUN_WATCH_WORKERS=20",
    "DIUN_WATCH_SCHEDULE=0 */6 * * *",
    "DIUN_WATCH_JITTER=30s",
    "DIUN_PROVIDERS_DOCKER=true",
    "DIUN_NOTIF_DISCORD_WEBHOOKURL=${var.discord_webhook}",
  ])

  command = [
    "serve",
  ]

  volumes = [
    {
      container_path = "/var/run/docker.sock"
      host_path      = "/var/run/docker.sock"
    },
    {
      container_path = "/data"
      host_path      = "/home/${var.username}/appdata/diun"
    },
  ]
}

data "cloudflare_zone" "reilley_dev" {
  filter = {
    name = var.domain
  }
}

module "ddns" {
  source = "./modules/service"

  domain = var.domain
  name   = "cloudflare-ddns"
  image  = "favonia/cloudflare-ddns:1.17.0"

  env = concat(local.shared_env, [
    "CLOUDFLARE_API_TOKEN=${var.cloudflare_api_token}",
    "DOMAINS=app.${var.domain}",
    "IP6_PROVIDER=none",
    "RECORD_COMMENT=managed by cloudflare-ddns",
  ])
}
