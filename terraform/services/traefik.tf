module "traefik" {
  source = "../modules/service"

  name      = "traefik"
  namespace = "ingress"
  image     = "traefik:latest"

  job_file = format("%s/jobs/ingress/traefik.nomad.hcl", path.module)
  job_vars = {
    acme_email = "reilleygray@gmail.com"
    consul_ca  = file(pathexpand("~/.homelab/pki/ca.crt"))
  }
  env = local.shared_env

  domain = var.domain
}

# The cutover apply forgets the Docker resources without deleting them, so
# docker start brings them back on rollback.
removed {
  from = module.traefik.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.traefik.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = docker_network.traefik

  lifecycle {
    destroy = false
  }
}
