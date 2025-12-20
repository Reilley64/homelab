module "bitwarden" {
  source = "./modules/service"

  name    = "bitwarden"
  image   = "vaultwarden/server:latest"
  public  = true
  port    = 80
  networks = [docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      container_path = "/data"
      host_path      = "/home/reilley/appdata/bitwarden"
    },
  ]
}
