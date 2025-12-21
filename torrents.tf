resource "docker_network" "torrents" {
  name   = "torrents"
  driver = "bridge"
}

module "gluetun" {
  source = "./modules/service"

  name       = "gluetun"
  image      = "qmcgaw/gluetun:v3.40.3"
  privileged = true

  capabilities = ["CAP_NET_ADMIN"]

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
  image   = "linuxserver/qbittorrent:5.1.4"
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
  ]
}
