resource "docker_network" "traefik" {
  name = "traefik"
  driver = "bridge"
}

module "traefik" {
  source = "./modules/service"

  name     = "traefik"
  image    = "traefik:latest"
  networks = [docker_network.traefik.id]

  env = local.shared_env

  command = [
    "--api.insecure=true",
    "--providers.docker=true",
    "--entrypoints.web.address=:80",
    "--entrypoints.websecure.address=:443",
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
