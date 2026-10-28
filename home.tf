resource "docker_network" "home" {
  name   = "home"
  driver = "bridge"
}

resource "docker_container" "homeassistant" {
  name    = "homeassistant"
  image   = docker_image.alpine.image_id
  restart = "unless-stopped"

  command = [
    "tail",
    "-f",
    "/dev/null",
  ]

  labels {
    label = "traefik.http.routers.homeassistant.rule"
    value = format("Host(`homeassistant.%s`)", var.domain)
  }

  labels {
    label = "traefik.http.routers.homeassistant.entrypoints"
    value = "websecure"
  }

  labels {
    label = "traefik.http.routers.homeassistant.tls.certresolver"
    value = "myresolver"
  }

  labels {
    label = "traefik.http.routers.homeassistant.service"
    value = "homeassistant"
  }

  labels {
    label = "traefik.http.services.homeassistant.loadbalancer.server.url"
    value = "http://192.168.86.139:8123"
  }
}

module "piper" {
  source = "./modules/service"

  domain   = var.domain
  name     = "piper"
  image    = "rhasspy/wyoming-piper:2.1.2"
  port     = 10200
  networks = [docker_network.home.id]

  ports = [
    {
      internal_port = 10200
      external_port = 10200
    },
  ]

  env = local.shared_env

  command = [
    "--voice=en_US-lessac-medium",
  ]

  volumes = [
    {
      container_path = "/data"
      host_path      = "/home/${var.username}/appdata/piper"
    },
  ]
}
