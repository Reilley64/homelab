locals {
  # The address Jellyfin sees Traefik connect from, on the internal host
  # network. It must match KnownProxies in appdata/jellyfin/network.xml, which
  # Jellyfin owns, so change both together.
  jellyfin_known_proxy = "10.91.0.1"
}

module "jellyfin" {
  source = "../modules/service"

  name      = "jellyfin"
  namespace = "media"
  image     = "linuxserver/jellyfin:latest"

  job_file = format("%s/jobs/media/jellyfin.nomad.hcl", path.module)
  job_vars = {
    logging_json = file(format("%s/config/jellyfin-logging.json", path.module))
  }
  env = local.shared_env

  domain             = var.domain
  host_address       = local.host_address
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
}

module "radarr" {
  source = "../modules/service"

  # Postgres must be registered in Consul before the database settings render.
  depends_on = [module.postgres]

  name      = "radarr"
  namespace = "media"
  image     = "linuxserver/radarr:latest"

  job_file = format("%s/jobs/media/radarr.nomad.hcl", path.module)
  job_vars = {
    database_user = var.username
  }
  env = local.shared_env

  domain       = var.domain
  host_address = local.host_address
  traefik      = true
}

module "sonarr" {
  source = "../modules/service"

  # Postgres must be registered in Consul before the database settings render.
  depends_on = [module.postgres]

  name      = "sonarr"
  namespace = "media"
  image     = "linuxserver/sonarr:latest"

  job_file = format("%s/jobs/media/sonarr.nomad.hcl", path.module)
  job_vars = {
    database_user = var.username
  }
  env = local.shared_env

  domain       = var.domain
  host_address = local.host_address
  traefik      = true
}

module "seerr" {
  source = "../modules/service"

  name      = "seerr"
  namespace = "media"
  image     = "seerr/seerr:latest"

  job_file = format("%s/jobs/media/seerr.nomad.hcl", path.module)
  env      = local.shared_env

  domain             = var.domain
  host_address       = local.host_address
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
}

module "prowlarr" {
  source = "../modules/service"

  name      = "prowlarr"
  namespace = "media"
  image     = "linuxserver/prowlarr:latest"

  job_file = format("%s/jobs/media/prowlarr.nomad.hcl", path.module)
  env      = local.shared_env

  domain       = var.domain
  host_address = local.host_address
  traefik      = true
}

module "flaresolverr" {
  source = "../modules/service"

  name      = "flaresolverr"
  namespace = "media"
  image     = "flaresolverr/flaresolverr:latest"

  job_file = format("%s/jobs/media/flaresolverr.nomad.hcl", path.module)
  env      = local.shared_env

  domain       = var.domain
  host_address = local.host_address
  traefik      = true
}

module "bazarr" {
  source = "../modules/service"

  name      = "bazarr"
  namespace = "media"
  image     = "linuxserver/bazarr:latest"

  job_file = format("%s/jobs/media/bazarr.nomad.hcl", path.module)
  env      = local.shared_env

  domain       = var.domain
  host_address = local.host_address
  traefik      = true
}

module "profilarr" {
  source = "../modules/service"

  name      = "profilarr"
  namespace = "media"
  image     = "ghcr.io/dictionarry-hub/profilarr:latest"

  job_file = format("%s/jobs/media/profilarr.nomad.hcl", path.module)
  env      = local.shared_env

  domain       = var.domain
  host_address = local.host_address
  traefik      = true
}

module "unpackerr" {
  source = "../modules/service"

  name      = "unpackerr"
  namespace = "media"
  image     = "golift/unpackerr:latest"

  job_file = format("%s/jobs/media/unpackerr.nomad.hcl", path.module)
  env      = local.shared_env

  domain       = var.domain
  host_address = local.host_address
}

module "selfless" {
  source = "../modules/service"

  depends_on = [module.postgres]

  name      = "selfless"
  namespace = "media"
  image     = "ghcr.io/reilley64/selfless:latest"

  job_file = format("%s/jobs/media/selfless.nomad.hcl", path.module)
  job_vars = {
    user          = format("%s:%s", var.uid, var.gid)
    database_user = var.username
    render_gid    = 28
    # The smtp_host output of the platform root.
    smtp_host = "email-smtp.ap-southeast-2.amazonaws.com"
    smtp_from = format("selfless <selfless@%s>", var.domain)
    # The admin password is the same as Grafana's, from Vault.
    admin_username = var.username
  }
  env = local.shared_env

  domain       = var.domain
  host_address = local.host_address
  traefik      = true

  traefik_tags = [
    "traefik.http.routers.selfless-sign-in.rule=Host(`selfless.localdomain`) && Method(`POST`) && (Path(`/api/sessions/v1`) || Path(`/admin/sign-in`))",
    "traefik.http.routers.selfless-sign-in.entrypoints=web",
    "traefik.http.routers.selfless-sign-in.service=selfless",
    "traefik.http.routers.selfless-sign-in.middlewares=selfless-sign-in-limit",
    "traefik.http.middlewares.selfless-sign-in-limit.ratelimit.average=5",
    "traefik.http.middlewares.selfless-sign-in-limit.ratelimit.period=1m",
    "traefik.http.middlewares.selfless-sign-in-limit.ratelimit.burst=5",
  ]
}
