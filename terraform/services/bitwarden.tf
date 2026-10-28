module "bitwarden" {
  source = "../modules/service"

  name      = "bitwarden"
  namespace = "bitwarden"
  image     = "vaultwarden/server:latest"

  job_file = format("%s/jobs/bitwarden/bitwarden.nomad.hcl", path.module)
  job_vars = {
    public_url = format("https://bitwarden.%s", var.domain)
  }
  env = local.shared_env

  domain             = var.domain
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
}

# The cutover apply forgets the Docker resources without deleting them, so
# docker start brings them back on rollback.
removed {
  from = module.bitwarden.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.bitwarden.docker_image.image

  lifecycle {
    destroy = false
  }
}
