provider "docker" {}

provider "caddy" {
  host = "unix:///run/caddy/admin.sock"
}

module "jellyfin" {
  source = "./modules/service"

  name    = "jellyfin"
  image   = "linuxserver/jellyfin:latest"
  network = docker_network.media.id

  env = [
    "TZ=Australia/Melbourne",
    "PGID=100",
    "PUID=1000",
  ]

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

resource "caddy_server" "https" {
  name   = "https"
  listen = [":443"]

  routes = [
    module.jellyfin.caddy_route,
  ]
}
