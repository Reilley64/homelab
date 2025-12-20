resource "docker_network" "home" {
  name   = "home"
  driver = "bridge"
}

module "piper" {
  source = "./modules/service"

  name    = "piper"
  image   = "rhasspy/wyoming-piper:latest"
  public  = true
  port    = 10200
  networks = [docker_network.home.id, docker_network.traefik.id]

  env = local.shared_env

  command = [
    "--voice=en_US-lessac-medium",
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
  image   = "rhasspy/wyoming-whisper:latest"
  public  = true
  port    = 10300
  networks = [docker_network.home.id, docker_network.traefik.id]

  env = local.shared_env

  command = [
    "--model=base",
    "--language=en",
  ]

  volumes = [
    {
      container_path = "/data"
      host_path      = "/home/reilley/appdata/whisper"
    },
  ]
}
