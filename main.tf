provider "docker" {}

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

  name  = "diun"
  image = "crazymax/diun:4.30.0"

  env = concat(local.shared_env, [
    "DIUN_WATCH_WORKERS=20",
    "DIUN_WATCH_SCHEDULE=0 */6 * * *",
    "DIUN_WATCH_JITTER=30s",
    "DIUN_PROVIDERS_DOCKER=true",
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
      host_path      = "/home/reilley/appdata/diun"
    },
  ]
}
