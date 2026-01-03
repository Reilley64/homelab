resource "docker_network" "arcto" {
  name   = "arcto"
  driver = "bridge"
}

resource "docker_image" "vaultwarden" {
  name         = "vaultwarden/server:1.35.1"
  keep_locally = false
}

resource "docker_container" "container" {
  image   = docker_image.vaultwarden.image_id
  name    = "arcto-vaultwarden"
  restart = "unless-stopped"
  env     = local.shared_env

  command = [
    "/start.sh"
  ]

  networks_advanced {
    name = docker_network.arcto.name
  }

  networks_advanced {
    name = docker_network.traefik.name
  }

  labels {
    label = "traefik.docker.network"
    value = "traefik"
  }

  labels {
    label = "traefik.http.services.arcto-vaultwarden.loadbalancer.server.port"
    value = "80"
  }

  labels {
    label = "traefik.http.routers.arcto-vaultwarden-local.rule"
    value = "Host(`vaultwarden.arcto.localdomain`)"
  }

  labels {
    label = "traefik.http.routers.arcto-vaultwarden-local.entrypoints"
    value = "web"
  }

  labels {
    label = "traefik.http.routers.arcto-vaultwarden-local.service"
    value = "arcto-vaultwarden"
  }

  volumes {
    container_path = "/data"
    host_path      = "/home/${var.username}/appdata/arcto/vaultwarden"
  }
}
