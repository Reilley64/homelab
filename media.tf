resource "docker_network" "media" {
  name   = "media"
  driver = "bridge"
}

module "jellyfin" {
  source = "./modules/service"

  name               = "jellyfin"
  image              = "linuxserver/jellyfin:10.11.6"
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
  image    = "linuxserver/radarr:version-6.0.4.10291"
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
  ]
}

module "sonarr" {
  source = "./modules/service"

  name     = "sonarr"
  image    = "linuxserver/sonarr:version-4.0.16.2944"
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
}

module "bazarr" {
  source = "./modules/service"

  name     = "bazarr"
  image    = "linuxserver/bazarr:1.5.5"
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
}
