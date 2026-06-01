resource "docker_network" "torrents" {
  name   = "torrents"
  driver = "bridge"
}

module "gluetun" {
  source = "./modules/service"

  name       = "gluetun"
  image      = "qmcgaw/gluetun:v3.41.1"
  privileged = true
  networks   = [docker_network.torrents.id]

  capabilities = ["CAP_NET_ADMIN"]

  env = concat(local.shared_env, [
    "VPN_SERVICE_PROVIDER=protonvpn",
    "VPN_TYPE=wireguard",
    "WIREGUARD_PRIVATE_KEY=${var.wireguard_private_key}",
    "PORT_FORWARD_ONLY=on",
    "VPN_PORT_FORWARDING=on",
    "VPN_PORT_FORWARDING_UP_COMMAND=/bin/sh -c 'wget -O- --retry-connrefused --post-data \"json={\\\"listen_port\\\":{{PORT}},\\\"current_network_interface\\\":\\\"{{VPN_INTERFACE}}\\\",\\\"random_port\\\":false,\\\"upnp\\\":false}\" http://127.0.0.1:8080/api/v2/app/setPreferences 2>&1'",
    "VPN_PORT_FORWARDING_DOWN_COMMAND=/bin/sh -c 'wget -O- --retry-connrefused --post-data \"json={\\\"listen_port\\\":0,\\\"current_network_interface\\\":\\\"lo\\\"}\" http://127.0.0.1:8080/api/v2/app/setPreferences 2>&1'",
  ])

  devices = [
    {
      container_path = "/dev/net/tun"
      host_path      = "/dev/net/tun"
    },
  ]

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
  image   = "linuxserver/qbittorrent:version-5.1.4-r3"
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
      host_path      = "/mnt/media"
    },
    {
      container_path = "/mnt/roms"
      host_path      = "/mnt/roms"
    },
  ]
}
