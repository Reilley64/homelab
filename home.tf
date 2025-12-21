resource "docker_network" "home" {
  name   = "home"
  driver = "bridge"
}

resource "docker_container" "homeassistant" {
  image        = docker_image.alpine.image_id
  name         = "homeassistant"
  restart      = "unless-stopped"

  command = [
    "tail",
    "-f",
    "/dev/null",
  ]

  labels {
    label = "traefik.http.routers.homeassistant.rule"
    value = "Host(`homeassistant.reilley.dev`)"
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

  name    = "piper"
  image   = "rhasspy/wyoming-piper:2.1.2"
  port    = 10200
  networks = [docker_network.home.id]

  env = local.shared_env

  command = [
    "--voice=en_US-lessac-medium",
  ]

  ports = [
    {
      internal_port = 10200
      external_port = 10200
    },
  ]

  volumes = [
    {
      container_path = "/data"
      host_path      = "/home/reilley/appdata/piper"
    },
  ]
}

module "whisper" {
  source = "./modules/service"

  name    = "whisper"
  image   = "rhasspy/wyoming-whisper:3.0.2"
  networks = [docker_network.home.id]

  env = local.shared_env

  command = [
    "--model=base",
    "--language=en",
  ]

  ports = [
    {
      internal_port = 10300
      external_port = 10300
    },
  ]

  volumes = [
    {
      container_path = "/data"
      host_path      = "/home/reilley/appdata/whisper"
    },
  ]
}
