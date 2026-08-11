module "bitwarden" {
  source = "./modules/service"

  domain             = var.domain
  name               = "bitwarden"
  image              = "vaultwarden/server:latest"
  port               = 80
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.traefik.id]

  env = concat(local.shared_env, [
    "DOMAIN=https://bitwarden.${var.domain}"
  ])

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
