resource "docker_network" "postgres" {
  name = "postgres"
  driver = "bridge"
}

module "postgres" {
  source = "./modules/service"

  name     = "postgres"
  image    = "postgres:14"
  networks = [docker_network.postgres.id]

  env = local.shared_env

  volumes = [
    {
      container_path = "/var/lib/postgresql/data"
      host_path      = "/home/reilley/appdata/postgres"
    },
  ]
}
