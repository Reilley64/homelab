resource "docker_network" "torrents" {
  name   = "torrents"
  driver = "bridge"
}

module "gluetun" {
  source = "./modules/service"

  domain     = var.domain
  name       = "gluetun"
  image      = "qmcgaw/gluetun:latest"
  route_name = "qbittorrent"
  url        = "http://192.168.86.199:8080"
  networks   = [docker_network.torrents.id]

  ports = [
    {
      internal_port = 8080
      external_port = 8080
    },
  ]

  env = concat(local.shared_env, [
    "VPN_SERVICE_PROVIDER=protonvpn",
    "VPN_TYPE=wireguard",
    "WIREGUARD_PRIVATE_KEY=${var.wireguard_private_key}",
    "PORT_FORWARD_ONLY=on",
    "VPN_PORT_FORWARDING=on",
    "VPN_PORT_FORWARDING_UP_COMMAND=/bin/sh -c 'wget -O- --retry-connrefused --post-data \"json={\\\"listen_port\\\":{{PORT}},\\\"current_network_interface\\\":\\\"{{VPN_INTERFACE}}\\\",\\\"random_port\\\":false,\\\"upnp\\\":false}\" http://127.0.0.1:8080/api/v2/app/setPreferences 2>&1'",
    "VPN_PORT_FORWARDING_DOWN_COMMAND=/bin/sh -c 'wget -O- --retry-connrefused --post-data \"json={\\\"listen_port\\\":0,\\\"current_network_interface\\\":\\\"lo\\\"}\" http://127.0.0.1:8080/api/v2/app/setPreferences 2>&1'",
  ])

  privileged   = true
  capabilities = ["CAP_NET_ADMIN"]

  devices = [
    {
      container_path = "/dev/net/tun"
      host_path      = "/dev/net/tun"
    },
  ]
}

module "qbittorrent" {
  source = "./modules/service"

  domain  = var.domain
  name    = "qbittorrent"
  image   = "linuxserver/qbittorrent:5.2.3"
  forward = "container:${module.gluetun.id}"

  env = concat(local.shared_env, [
    "WEBUI_PORT=8080",
  ])

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/${var.username}/appdata/qbittorrent"
    },
    {
      container_path = "/downloads"
      host_path      = "/home/${var.username}/downloads"
    },
    {
      container_path = "/mnt/media"
      host_path      = module.media.target
    },
    {
      container_path = "/mnt/roms"
      host_path      = module.roms.target
    },
  ]
}
