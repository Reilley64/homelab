resource "docker_network" "arcto" {
  name   = "arcto"
  driver = "bridge"
}

resource "docker_image" "authentik_postgres" {
  name         = "postgres:16-alpine"
  keep_locally = false
}

resource "docker_container" "authentik_postgres" {
  image   = docker_image.authentik_postgres.image_id
  name    = "arcto-authentik-database"
  restart = "unless-stopped"

  env = concat(local.shared_env, [
    "POSTGRES_DB=authentik",
    "POSTGRES_USER=${var.username}",
    "POSTGRES_PASSWORD=${var.password}",
  ])

  networks_advanced {
    name = docker_network.arcto.name
  }
}

resource "docker_image" "authentik" {
  name         = "ghcr.io/goauthentik/server:2025.10.3"
  keep_locally = false
}

resource "random_password" "authentik_secret_key" {
  length = 60
}

output "authentik_secret_key" {
  value     = random_password.authentik_secret_key.result
  sensitive = true
}

resource "docker_container" "authentik" {
  image   = docker_image.authentik.image_id
  name    = "arcto-authentik-server"
  restart = "unless-stopped"

  env = concat(local.shared_env, [
    "AUTHENTIK_POSTGRESQL__HOST=postgresql",
    "AUTHENTIK_POSTGRESQL__NAME=authentik",
    "AUTHENTIK_POSTGRESQL__USER=${var.username}",
    "AUTHENTIK_POSTGRESQL__PASSWORD=${var.password}",
    "AUTHENTIK_SECRET_KEY=${random_password.authentik_secret_key.result}",
  ])

  command = [
    "server"
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
    label = "traefik.http.services.arcto-authentik.loadbalancer.server.port"
    value = "9443"
  }

  labels {
    label = "traefik.http.routers.arcto-authentik.rule"
    value = "Host(`authentik.arctopayments.com.au`)"
  }

  labels {
    label = "traefik.http.routers.arcto-authentik.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.arcto-authentik.tls.certresolver"
    value = "myresolver"
  }

  labels {
    label = "traefik.http.routers.arcto-authentik.service"
    value = "arcto-authentik"
  }

  volumes {
    container_path = "/media"
    host_path      = "/home/${var.username}/appdata/arcto/authentik/media"
  }

  volumes {
    container_path = "/templates"
    host_path      = "/home/${var.username}/appdata/arcto/authentik/templates"
  }
}

resource "docker_container" "authentik_worker" {
  image   = docker_image.authentik.image_id
  name    = "arcto-authentik-worker"
  restart = "unless-stopped"

  env = concat(local.shared_env, [
    "AUTHENTIK_POSTGRESQL__HOST=postgresql",
    "AUTHENTIK_POSTGRESQL__NAME=authentik",
    "AUTHENTIK_POSTGRESQL__USER=${var.username}",
    "AUTHENTIK_POSTGRESQL__PASSWORD=${var.password}",
    "AUTHENTIK_SECRET_KEY=${random_password.authentik_secret_key.result}",
  ])

  command = [
    "worker"
  ]

  networks_advanced {
    name = docker_network.arcto.name
  }

  volumes {
    container_path = "/var/run/docker.sock"
    host_path      = "/var/run/docker.sock"
  }

  volumes {
    container_path = "/media"
    host_path      = "/home/${var.username}/appdata/arcto/authentik/media"
  }

  volumes {
    container_path = "/certs"
    host_path      = "/home/${var.username}/appdata/arcto/authentik/certs"
  }

  volumes {
    container_path = "/templates"
    host_path      = "/home/${var.username}/appdata/arcto/authentik/templates"
  }
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
