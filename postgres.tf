resource "docker_network" "postgres" {
  name = "postgres"
  driver = "bridge"
}

module "postgres" {
  source = "./modules/service"

  name     = "postgres"
  image    = "postgres:14"
  networks = [docker_network.postgres.id]

  env = concat(local.shared_env, [
    "POSTGRES_USER=${var.username}",
    "POSTGRES_PASSWORD=${var.password}",
  ])

  volumes = [
    {
      container_path = "/var/lib/postgresql/data"
      host_path      = "/home/reilley/appdata/postgres"
    },
  ]
}
