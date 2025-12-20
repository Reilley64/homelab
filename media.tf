resource "docker_network" "media" {
  name = "media"
  driver = "bridge"
}

module "jellyfin" {
  source = "./modules/service"

  name     = "jellyfin"
  image    = "linuxserver/jellyfin:latest"
  networks = [docker_network.media.id]

  env = local.shared_env

  devices = [
    {
      container_path = "/dev/dri"
      host_path      = "/dev/dri"
    },
  ]

  ports = [
    {
      internal_port = 8096
      external_port = 8096
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
