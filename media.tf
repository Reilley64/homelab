resource "docker_network" "media" {
  name   = "media"
  driver = "bridge"
}

module "jellyfin" {
  source = "./modules/service"

  name     = "jellyfin"
  image    = "linuxserver/jellyfin:10.11.5"
  public   = true
  port     = 8096
  networks = [docker_network.media.id, docker_network.postgres.id, docker_network.traefik.id]

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
  image    = "linuxserver/radarr:6.0.4"
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
  image    = "linuxserver/sonarr:4.0.16"
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

module "prowlarr" {
  source = "./modules/service"

  name     = "prowlarr"
  image    = "linuxserver/prowlarr:2.3.0"
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

module "profilarr" {
  source = "./modules/service"

  name     = "profilarr"
  image    = "santiagosayshey/profilarr:v1.1.3"
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
