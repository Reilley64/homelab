resource "docker_network" "immich" {
  name   = "immich"
  driver = "bridge"
}

locals {
  immich_env = [
    "DB_HOSTNAME=localhost",
    "DB_USERNAME=${var.username}",
    "DB_PASSWORD=${var.password}",
    "DB_DATABASE_NAME=immich",
  ]
}

module "immich_server" {
  source = "./modules/service"

  name     = "immich_server"
  image    = "ghcr.io/immich-app/immich-server:v2.5.6"
  port     = 2283
  networks = [docker_network.immich.id, docker_network.postgres.id, docker_network.traefik.id]

  env = concat(local.shared_env, local.immich_env)

  volumes = [
    {
      container_path = "/data"
      host_path      = "/mnt/photos"
    }
  ]
}

module "immich_machine_learning" {
  source = "./modules/service"

  name     = "immich_machine_learning"
  image    = "ghcr.io/immich-app/immich-machine-learning:v2.5.6-openvino"
  networks = [docker_network.immich.id, docker_network.postgres.id]

  env = concat(local.shared_env, local.immich_env)

  volumes = [
    {
      container_path = "/data"
      host_path      = "/home/${var.username}/appdata/whisper"
    }
  ]
}

module "immich_redis" {
  source = "./modules/service"

  name     = "immich_redis"
  image    = "valkey/valkey:9"
  networks = [docker_network.immich.id]

  env = local.shared_env
}
