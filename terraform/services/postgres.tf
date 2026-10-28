module "postgres" {
  source = "../modules/service"

  name      = "postgres"
  namespace = "data"
  image     = "postgres:14.24"

  job_file = format("%s/jobs/data/postgres.nomad.hcl", path.module)
  job_vars = {
    database_user = var.username
  }
  env = local.shared_env

  domain = var.domain
}

# The dumps the nightly backup saves. The backup script checks they are fresh.
module "postgres_dump" {
  source = "../modules/service"

  name      = "postgres-dump"
  namespace = "ops"
  image     = "postgres:14.24"

  job_file = format("%s/jobs/ops/postgres-dump.nomad.hcl", path.module)
  job_vars = {
    database_user = var.username
  }
  env = local.shared_env

  domain = var.domain
}

# The cutover apply forgets the Docker resources without deleting them, so
# docker start brings them back on rollback.
removed {
  from = module.postgres.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.postgres.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = docker_network.postgres

  lifecycle {
    destroy = false
  }
}
