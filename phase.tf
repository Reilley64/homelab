module "phase" {
  source = "./modules/service"

  name               = "phase"
  image              = "ghcr.io/phase-rs/phase-server:latest"
  public             = true
  port               = 9374
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.traefik.id]

  env = concat(local.shared_env, [
    "PHASE_CORS_ORIGIN=*"
  ])

  volumes = [
    {
      container_path = "/var/lib/phase-server"
      host_path      = "/home/${var.username}/appdata/phase"
    },
  ]
}