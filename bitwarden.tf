module "bitwarden" {
  source = "./modules/service"

  name               = "bitwarden"
  image              = "vaultwarden/server:1.34.3"
  public             = true
  port               = 80
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.traefik.id]

  env = local.shared_env

  command = [
    "/start.sh"
  ]

  volumes = [
    {
      container_path = "/data"
      host_path      = "/home/${var.username}/appdata/bitwarden"
    },
  ]
}
