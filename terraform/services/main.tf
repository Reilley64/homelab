locals {
  shared_env = {
    TZ   = "Australia/Melbourne"
    PGID = var.gid
    PUID = var.uid
  }
}

data "cloudflare_zone" "reilley_dev" {
  filter = {
    name = var.domain
  }
}

module "diun" {
  source = "../modules/service"

  name      = "diun"
  namespace = "ops"
  image     = "crazymax/diun:4.33.1"

  job_file = format("%s/jobs/ops/diun.nomad.hcl", path.module)
  env      = local.shared_env

  domain = var.domain
}

module "cloudflare_ddns" {
  source = "../modules/service"

  name      = "cloudflare-ddns"
  namespace = "ops"
  image     = "favonia/cloudflare-ddns:1.17.0"

  job_file = format("%s/jobs/ops/cloudflare-ddns.nomad.hcl", path.module)
  job_vars = {
    domains = format("app.%s", var.domain)
  }
  env = local.shared_env

  domain = var.domain
}

# The cutover apply forgets the Docker resources without deleting them, so
# docker start brings them back on rollback.
removed {
  from = module.diun.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.diun.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.ddns.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.ddns.docker_image.image

  lifecycle {
    destroy = false
  }
}
