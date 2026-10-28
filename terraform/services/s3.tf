locals {
  s3_clients = toset(["tabletop"])
}

module "s3" {
  source = "../modules/service"

  name      = "s3"
  namespace = "data"
  image     = "rclone/rclone:1.75.2"

  job_file = format("%s/jobs/data/s3.nomad.hcl", path.module)
  job_vars = {
    s3_clients = local.s3_clients
  }
  env = local.shared_env

  domain             = var.domain
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
}

# The cutover apply forgets the Docker resources without deleting them, so
# docker start brings them back on rollback.
removed {
  from = module.s3.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.s3.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = docker_network.s3

  lifecycle {
    destroy = false
  }
}

# These keys now live in Vault at kv/data/s3 and kv/tabletop/tabletop. Copy
# them from the state into Vault before the cutover apply forgets them.
removed {
  from = random_password.s3_rc_password

  lifecycle {
    destroy = false
  }
}

removed {
  from = random_password.s3_access_key

  lifecycle {
    destroy = false
  }
}

removed {
  from = random_password.s3_secret_key

  lifecycle {
    destroy = false
  }
}
