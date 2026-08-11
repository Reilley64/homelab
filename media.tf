resource "docker_network" "media" {
  name   = "media"
  driver = "bridge"
}

module "jellyfin" {
  source = "./modules/service"

  domain             = var.domain
  name               = "jellyfin"
  image              = "linuxserver/jellyfin:latest"
  port               = 8096
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.media.id, docker_network.traefik.id]

  env = local.shared_env

  uploads = [
    {
      file    = "/config/logging.json"
      content = file("${path.module}/observability/jellyfin-logging.json")
    },
  ]

  devices = [
    {
      container_path = "/dev/dri"
      host_path      = "/dev/dri"
    },
  ]

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/${var.username}/appdata/jellyfin"
    },
    {
      container_path = "/mnt/media"
      host_path      = module.media.target
    },
  ]
}

module "radarr" {
  source     = "./modules/service"
  depends_on = [module.postgres]

  domain   = var.domain
  name     = "radarr"
  image    = "linuxserver/radarr:latest"
  port     = 7878
  networks = [docker_network.media.id, docker_network.postgres.id, docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/${var.username}/appdata/radarr"
    },
    {
      container_path = "/mnt/media"
      host_path      = module.media.target
    },
    {
      container_path = "/downloads"
      host_path      = "/home/${var.username}/downloads"
    },
  ]
}

module "sonarr" {
  source     = "./modules/service"
  depends_on = [module.postgres]

  domain   = var.domain
  name     = "sonarr"
  image    = "linuxserver/sonarr:latest"
  port     = 8989
  networks = [docker_network.media.id, docker_network.postgres.id, docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/${var.username}/appdata/sonarr"
    },
    {
      container_path = "/mnt/media"
      host_path      = module.media.target
    },
    {
      container_path = "/downloads"
      host_path      = "/home/${var.username}/downloads"
    },
  ]
}

module "seerr" {
  source = "./modules/service"

  domain             = var.domain
  name               = "seerr"
  image              = "seerr/seerr:latest"
  port               = 5055
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.media.id, docker_network.traefik.id]

  env = local.shared_env

  command = [
    "npm",
    "start",
  ]

  volumes = [
    {
      container_path = "/app/config"
      host_path      = "/home/${var.username}/appdata/seerr"
    },
  ]
}

module "prowlarr" {
  source = "./modules/service"

  domain   = var.domain
  name     = "prowlarr"
  image    = "linuxserver/prowlarr:latest"
  port     = 9696
  networks = [docker_network.media.id, docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/${var.username}/appdata/prowlarr"
    },
  ]
}

module "flaresolverr" {
  source = "./modules/service"

  domain   = var.domain
  name     = "flaresolverr"
  image    = "flaresolverr/flaresolverr:latest"
  port     = 8191
  networks = [docker_network.media.id, docker_network.traefik.id]

  env = local.shared_env

  command = [
    "/usr/local/bin/python",
    "-u",
    "/app/flaresolverr.py",
  ]
}

module "bazarr" {
  source = "./modules/service"

  domain   = var.domain
  name     = "bazarr"
  image    = "linuxserver/bazarr:latest"
  port     = 6767
  networks = [docker_network.media.id, docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/${var.username}/appdata/bazarr"
    },
    {
      container_path = "/mnt/media"
      host_path      = module.media.target
    },
  ]
}

module "profilarr" {
  source = "./modules/service"

  domain   = var.domain
  name     = "profilarr"
  image    = "ghcr.io/dictionarry-hub/profilarr:latest"
  port     = 6868
  networks = [docker_network.media.id, docker_network.traefik.id]

  env = concat(local.shared_env, [
    "AUTH=off",
  ])

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/${var.username}/appdata/profilarr"
    },
  ]
}

module "unpackerr" {
  source = "./modules/service"

  domain   = var.domain
  name     = "unpackerr"
  image    = "golift/unpackerr:latest"
  networks = [docker_network.media.id]

  env = concat(local.shared_env, [
    "UN_LOG_FILE=/logs/unpackerr.log",
    "UN_SONARR_0_URL=http://sonarr.localdomain",
    "UN_SONARR_0_API_KEY=${var.sonarr_api_key}",
    "UN_RADARR_0_URL=http://radarr.localdomain",
    "UN_RADARR_0_API_KEY=${var.radarr_api_key}",
  ])

  volumes = [
    {
      container_path = "/logs"
      host_path      = "/home/${var.username}/appdata/unpackerr"
    },
    {
      container_path = "/mnt/media"
      host_path      = module.media.target
    },
  ]
}
