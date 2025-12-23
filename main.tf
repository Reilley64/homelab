provider "docker" {}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  shared_env = [
    "TZ=Australia/Melbourne",
    "PGID=1000",
    "PUID=1000",
  ]
}

resource "docker_image" "alpine" {
  name         = "alpine:latest"
  keep_locally = false
}

module "diun" {
  source = "./modules/service"

  name               = "diun"
  image              = "crazymax/diun:4.30.0"

  env = concat(local.shared_env, [
    "DIUN_WATCH_WORKERS=20",
    "DIUN_WATCH_SCHEDULE=0 */6 * * *",
    "DIUN_WATCH_JITTER=30s",
    "DIUN_PROVIDERS_DOCKER=true",
    "DIUN_NOTIF_DISCORD_WEBHOOKURL=${var.diun_webhook}",
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

data "http" "myip" {
  url = "https://ipv4.icanhazip.com"
}

data "cloudflare_zone" "reilley_dev" {
  filter = {
    name = "reilley.dev"
  }
}

resource "cloudflare_dns_record" "app" {
  zone_id = data.cloudflare_zone.reilley_dev.id
  name    = "app"
  ttl     = 1
  type    = "A"
  content = data.http.myip.response_body
}
