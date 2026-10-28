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
    format("DOMAIN=https://bitwarden.%s", var.domain)
  ])

  command = [
    "/start.sh"
  ]

  volumes = [
    {
      container_path = "/data"
      host_path      = format("/home/%s/appdata/bitwarden", var.username)
    },
  ]
}
