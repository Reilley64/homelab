module "torrents" {
  source = "../modules/service"

  name      = "torrents"
  namespace = "torrents"
  image     = "linuxserver/qbittorrent:5.2.3-libtorrentv1"

  job_file = format("%s/jobs/torrents/torrents.nomad.hcl", path.module)
  job_vars = {
    # The digest of the latest image running today. Nomad never re-pulls a tag.
    gluetun_image = "qmcgaw/gluetun:latest@sha256:c2ee4191762fca6b6a3c3359a731198a95d9c9af4db32d466e223bf3a84e779b"
    wait_image    = "busybox:1.37"
  }
  env = local.shared_env

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
