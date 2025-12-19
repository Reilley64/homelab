provider "docker" {}

provider "caddy" {
  host = "unix:///run/caddy/admin.sock"
}

# module "bitwarden" {
#   source = "./modules/service"
#
#   name    = "bitwarden"
#   image   = "vaultwarden/server:latest"
#   network = docker_network.media.id
#
#   env = [
#     "TZ=Australia/Melbourne",
#     "PGID=1000",
#     "PUID=1000",
#   ]
#
#   ports = [
#     {
#       internal_port = 80
#       external_port = 800
#     },
#   ]
#
#   volumes = [
#     {
#       container_path = "/data"
#       host_path      = "/home/reilley/appdata/bitwarden"
#     },
#   ]
# }

locals {
  shared_env = [
    "TZ=Australia/Melbourne",
    "PGID=1000",
    "PUID=1000",
  ]
}

module "jellyfin" {
  source = "./modules/service"

  name    = "jellyfin"
  image   = "linuxserver/jellyfin:latest"
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

module "gluetun" {
  source = "./modules/service"

  name    = "gluetun"
  image   = "qmcgaw/gluetun:latest"

  capabilities = ["NET_ADMIN"]

  env = concat(local.shared_env, [
    "VPN_SERVICE_PROVIDER=protonvpn",
    "VPN_TYPE=wireguard",
    "WIREGUARD_PRIVATE_KEY=SKfx08T9jVPuQPDuNBL3n5l9iXR5dSw+7R5zvSCLVU0=",
    "PORT_FORWARD_ONLY=on",
    "VPN_PORT_FORWARDING=on",
    "VPN_PORT_FORWARDING_UP_COMMAND=/bin/sh -c 'wget -O- --retry-connrefused --post-data \"json={\"listen_port\":{{PORTS}}}\" http://localhost:8080/api/v2/app/setPreferences 2>&1'",
  ])

  ports = [
    {
      internal_port = 8080
      external_port = 8080
    },
  ]
}

module "qbittorrent" {
  source = "./modules/service"

  name    = "qbittorrent"
  image   = "linuxserver/qbittorrent:latest"
  forward = "service:gluetun"

  env = concat(local.shared_env, [
    "WEBUI_PORT=8080",
  ])

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/reilley/appdata/qbittorrent"
    },
    {
      container_path = "/downloads"
      host_path      = "/home/reilley/downloads"
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
    module.jellyfin.caddy_route.id,
  ]
}
