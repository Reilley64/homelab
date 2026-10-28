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

moved {
  from = module.gluetun.unifi_dns_record.local
  to   = module.torrents.unifi_dns_record.local
}

# The cutover apply forgets the Docker resources without deleting them, so
# docker start brings them back on rollback.
removed {
  from = module.gluetun.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.gluetun.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.qbittorrent.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.qbittorrent.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = docker_network.torrents

  lifecycle {
    destroy = false
  }
}
