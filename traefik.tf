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
    "--certificatesresolvers.myresolver.acme.tlschallenge=true",
    "--certificatesresolvers.myresolver.acme.email=reilleygray@gmail.com",
    "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json",
  ]

  ports = [
    {
      internal_port = 80
      external_port = 80
    },
    {
      internal_port = 443
      external_port = 443
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
    {
      container_path = "/letsencrypt"
      host_path      = "/home/reilley/appdata/letsencrypt"
    },
  ]
}
