resource "docker_network" "arcto" {
  name   = "arcto"
  driver = "bridge"
}

resource "docker_image" "vaultwarden" {
  name         = "vaultwarden/server:1.35.1"
  keep_locally = false
}

resource "docker_container" "vaultwarden" {
  image   = docker_image.vaultwarden.image_id
  name    = "arcto-vaultwarden"
  restart = "unless-stopped"

  env = concat(local.shared_env, [
    "ADMIN_TOKEN=${var.arcto_vaultwarden_admin_token}",
  ])

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
    label = "traefik.http.routers.arcto-vaultwarden.rule"
    value = "Host(`vaultwarden.arctopayments.com.au`)"
  }

  labels {
    label = "traefik.http.routers.arcto-vaultwarden.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.arcto-vaultwarden.tls.certresolver"
    value = "myresolver"
  }

  labels {
    label = "traefik.http.routers.arcto-vaultwarden.service"
    value = "arcto-vaultwarden"
  }

  volumes {
    container_path = "/data"
    host_path      = "/home/${var.username}/appdata/arcto/vaultwarden"
  }

  ports {
    internal = 80
    external = 8000
  }
}
