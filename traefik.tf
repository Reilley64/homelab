module "traefik" {
  source = "./modules/service"

  name     = "traefik"
  image    = "traefik:latest"

  env = local.shared_env
  command = [
    "--api.insecure=true",
    "--providers.docker=true",
    "--entrypoints.web.address=:80",
  ]

  ports = [
    {
      internal_port = 80
      external_port = 80
    },
    {
      internal_port = 8080
      external_port = 4040
    },
  ]

  volumes = [
    {
      container_path = "/var/run/docker.sock"
      host_path      = "/var/run/docker.sock"
    },
  ]
}
