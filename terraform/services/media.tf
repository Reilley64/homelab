locals {
  # REHEARSAL CHECK: the address Jellyfin sees Traefik connect from. It goes
  # into KnownProxies in appdata/jellyfin/network.xml by hand at the cutover.
  # Traefik reaches Jellyfin on the internal host network, so this should be
  # 10.91.0.1. If Jellyfin's logs show the bridge gateway 10.90.0.1 instead,
  # change it here and in network.xml.
  jellyfin_known_proxy = "10.91.0.1"
}

module "jellyfin" {
  source = "../modules/service"

  name      = "jellyfin"
  namespace = "media"
  image     = "linuxserver/jellyfin:12.3ubu2604-ls56"

  job_file = format("%s/jobs/media/jellyfin.nomad.hcl", path.module)
  job_vars = {
    logging_json = file(format("%s/config/jellyfin-logging.json", path.module))
  }
  env = local.shared_env

  domain             = var.domain
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
}

removed {
  from = module.jellyfin.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.jellyfin.docker_image.image

  lifecycle {
    destroy = false
  }
}

module "radarr" {
  source = "../modules/service"

  # Postgres must be registered in Consul before the database settings render.
  depends_on = [module.postgres]

  name      = "radarr"
  namespace = "media"
  image     = "linuxserver/radarr:6.4.4.10685-ls323"

  job_file = format("%s/jobs/media/radarr.nomad.hcl", path.module)
  job_vars = {
    database_user = var.username
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

removed {
  from = module.radarr.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.radarr.docker_image.image

  lifecycle {
    destroy = false
  }
}

module "sonarr" {
  source = "../modules/service"

  # Postgres must be registered in Consul before the database settings render.
  depends_on = [module.postgres]

  name      = "sonarr"
  namespace = "media"
  image     = "linuxserver/sonarr:4.0.20.3014-ls1"

  job_file = format("%s/jobs/media/sonarr.nomad.hcl", path.module)
  job_vars = {
    database_user = var.username
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

removed {
  from = module.sonarr.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.sonarr.docker_image.image

  lifecycle {
    destroy = false
  }
}

module "seerr" {
  source = "../modules/service"

  name      = "seerr"
  namespace = "media"
  image     = "seerr/seerr:v3.5.1"

  job_file = format("%s/jobs/media/seerr.nomad.hcl", path.module)
  env      = local.shared_env

  domain             = var.domain
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
}

removed {
  from = module.seerr.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.seerr.docker_image.image

  lifecycle {
    destroy = false
  }
}

module "prowlarr" {
  source = "../modules/service"

  name      = "prowlarr"
  namespace = "media"
  image     = "linuxserver/prowlarr:2.6.5.5623-ls165"

  job_file = format("%s/jobs/media/prowlarr.nomad.hcl", path.module)
  env      = local.shared_env

  domain  = var.domain
  traefik = true
}

removed {
  from = module.prowlarr.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.prowlarr.docker_image.image

  lifecycle {
    destroy = false
  }
}

module "flaresolverr" {
  source = "../modules/service"

  name      = "flaresolverr"
  namespace = "media"
  image     = "flaresolverr/flaresolverr:v3.5.2"

  job_file = format("%s/jobs/media/flaresolverr.nomad.hcl", path.module)
  env      = local.shared_env

  domain  = var.domain
  traefik = true
}

removed {
  from = module.flaresolverr.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.flaresolverr.docker_image.image

  lifecycle {
    destroy = false
  }
}

module "bazarr" {
  source = "../modules/service"

  name      = "bazarr"
  namespace = "media"
  image     = "linuxserver/bazarr:v1.6.2-ls369"

  job_file = format("%s/jobs/media/bazarr.nomad.hcl", path.module)
  env      = local.shared_env

  domain  = var.domain
  traefik = true
}

removed {
  from = module.bazarr.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.bazarr.docker_image.image

  lifecycle {
    destroy = false
  }
}

module "profilarr" {
  source = "../modules/service"

  name      = "profilarr"
  namespace = "media"
  image     = "ghcr.io/dictionarry-hub/profilarr:2.3.1"

  job_file = format("%s/jobs/media/profilarr.nomad.hcl", path.module)
  env      = local.shared_env

  domain  = var.domain
  traefik = true
}

removed {
  from = module.profilarr.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.profilarr.docker_image.image

  lifecycle {
    destroy = false
  }
}

module "unpackerr" {
  source = "../modules/service"

  name      = "unpackerr"
  namespace = "media"
  image     = "golift/unpackerr:0.16.1"

  job_file = format("%s/jobs/media/unpackerr.nomad.hcl", path.module)
  env      = local.shared_env

  domain = var.domain
}

removed {
  from = module.unpackerr.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.unpackerr.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = docker_network.media

  lifecycle {
    destroy = false
  }
}
