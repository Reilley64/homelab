resource "docker_network" "postgres" {
  name   = "postgres"
  driver = "bridge"
}

module "postgres" {
  source = "./modules/service"

  domain   = var.domain
  name     = "postgres"
  image    = "postgres:14"
  networks = [docker_network.postgres.id]

  ports = [
    {
      internal_port = 5432
      external_port = 5432
    }
  ]

  env = concat(local.shared_env, [
    format("POSTGRES_USER=%s", var.username),
    format("POSTGRES_PASSWORD=%s", var.password),
  ])

  command = [
    "postgres",
  ]

  volumes = [
    {
      container_path = "/var/lib/postgresql/data"
      host_path      = format("/home/%s/appdata/postgres", var.username)
    },
  ]
}
