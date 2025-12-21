resource "docker_network" "media" {
  name   = "media"
  driver = "bridge"
}

module "jellyfin" {
  source = "./modules/service"

  name     = "jellyfin"
  image    = "linuxserver/jellyfin:latest"
  public   = true
  port     = 8096
  networks = [docker_network.media.id, docker_network.postgres.id, docker_network.traefik.id]

  env = local.shared_env

  devices = [
    {
      container_path = "/dev/dri"
      host_path      = "/dev/dri"
    },
  ]

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/reilley/appdata/jellyfin"
    },
    {
      container_path = "/mnt/media"
      host_path      = "/mnt/media"
    },
  ]
}

module "radarr" {
  source = "./modules/service"

  name     = "radarr"
  image    = "linuxserver/radarr:latest"
  port     = 7878
  networks = [docker_network.media.id, docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/reilley/appdata/radarr"
    },
    {
      container_path = "/mnt/media"
      host_path      = "/mnt/media"
    },
  ]
}
