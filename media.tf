resource "docker_network" "media" {
  name   = "media"
  driver = "bridge"
}

module "jellyfin" {
  source = "./modules/service"

  name               = "jellyfin"
  image              = "linuxserver/jellyfin:version-10.11.8ubu2404"
  public             = true
  port               = 8096
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.media.id, docker_network.postgres.id, docker_network.traefik.id]

  env = local.shared_env

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
      host_path      = "/mnt/media"
    },
  ]
}

module "radarr" {
  source = "./modules/service"

  name     = "radarr"
  image    = "linuxserver/radarr:version-6.1.1.10360"
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
      host_path      = "/mnt/media"
    },
    {
      container_path = "/downloads"
      host_path      = "/home/${var.username}/downloads"
    },
  ]
}

module "sonarr" {
  source = "./modules/service"

  name     = "sonarr"
  image    = "linuxserver/sonarr:version-4.0.17.2952"
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
      host_path      = "/mnt/media"
    },
    {
      container_path = "/downloads"
      host_path      = "/home/${var.username}/downloads"
    },
  ]
}

module "seerr" {
  source = "./modules/service"

  name     = "seerr"
  image    = "seerr/seerr:v3.1.0"
  public   = true
  port     = 5055
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks = [docker_network.media.id, docker_network.postgres.id, docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      container_path = "/app/config"
      host_path      = "/home/${var.username}/appdata/seerr"
    },
  ]

  command = [
    "npm",
    "start",
  ]
}

module "prowlarr" {
  source = "./modules/service"

  name     = "prowlarr"
  image    = "linuxserver/prowlarr:version-2.3.0.5236"
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

  name     = "flaresolverr"
  image    = "flaresolverr/flaresolverr:v3.4.6"
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

  name     = "bazarr"
  image    = "linuxserver/bazarr:version-v1.5.6"
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
      host_path      = "/mnt/media"
    },
  ]
}

module "profilarr" {
  source = "./modules/service"

  name     = "profilarr"
  image    = "santiagosayshey/profilarr:v1.1.4"
  port     = 6868
  networks = [docker_network.media.id, docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      container_path = "/config"
      host_path      = "/home/${var.username}/appdata/profilarr"
    },
  ]

  command = [
    "gunicorn",
    "--bind",
    "0.0.0.0:6868",
    "--timeout",
    "600",
    "app.main:create_app()",
  ]
}

module "unpackerr" {
  source = "./modules/service"

  name = "unpackerr"
  image = "golift/unpackerr:0.15.2"
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
      host_path      = "/mnt/media"
    },
  ]
}
