module "torrents" {
  source = "../modules/service"

  name      = "torrents"
  namespace = "torrents"
  image     = "linuxserver/qbittorrent:5.2.3-libtorrentv1"
  images = {
    gluetun_image = "qmcgaw/gluetun:latest"
    wait_image    = "busybox:1.37"
  }

  job_file = format("%s/jobs/torrents/torrents.nomad.hcl", path.module)
  env      = local.shared_env

  domain     = var.domain
  route_name = "qbittorrent"
  traefik    = true
}
