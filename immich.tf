resource "docker_network" "immich" {
  name   = "immich"
  driver = "bridge"
}

locals {
  immich_env = [
    "DB_URL=postgresql://${var.username}:${var.password}@immich-postgres:5432/immich",
    "REDIS_HOSTNAME=immich-redis"
  ]
}

module "immich" {
  source = "./modules/service"

  name               = "immich"
  image              = "ghcr.io/immich-app/immich-server:v2.5.6"
  public             = true
  port               = 2283
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.immich.id, docker_network.traefik.id]

  env = concat(local.shared_env, local.immich_env)

  command = ["start.sh"]

  volumes = [
    {
      container_path = "/data"
      host_path      = "/mnt/photos"
    }
  ]
}

module "immich_machine_learning" {
  source = "./modules/service"

  name     = "immich-machine-learning"
  image    = "ghcr.io/immich-app/immich-machine-learning:v2.5.6-openvino"
  networks = [docker_network.immich.id]

  env = concat(local.shared_env, local.immich_env)

  command = ["python", "-m", "immich_ml"]

  volumes = [
    {
      container_path = "/data"
      host_path      = "/home/${var.username}/appdata/immich/cache"
    }
  ]
}

module "immich_redis" {
  source = "./modules/service"

  name     = "immich-redis"
  image    = "valkey/valkey:9"
  networks = [docker_network.immich.id]

  env = local.shared_env

  command = ["valkey-server"]
}

module "immich_postgres" {
  source = "./modules/service"

  name     = "immich-postgres"
  image    = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"
  networks = [docker_network.immich.id]

  env = concat(local.shared_env, [
    "POSTGRES_USER=${var.username}",
    "POSTGRES_PASSWORD=${var.password}",
    "POSTGRES_DB=immich"
  ])

  command = ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]

  volumes = [
    {
      container_path = "/var/lib/postgresql/data"
      host_path      = "/home/${var.username}/appdata/immich/database"
    },
  ]
}
