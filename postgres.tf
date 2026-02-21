resource "docker_network" "postgres" {
  name   = "postgres"
  driver = "bridge"
}

module "postgres" {
  source = "./modules/service"

  name     = "postgres"
  image    = "postgres:14.21"
  networks = [docker_network.postgres.id]

  env = concat(local.shared_env, [
    "POSTGRES_USER=${var.username}",
    "POSTGRES_PASSWORD=${var.password}",
  ])

  command = [
    "postgres",
  ]

  ports = [
    {
      internal_port = 5432
      external_port = 5432
    }
  ]

  volumes = [
    {
      container_path = "/var/lib/postgresql/data"
      host_path      = "/home/${var.username}/appdata/postgres"
    },
  ]
}
