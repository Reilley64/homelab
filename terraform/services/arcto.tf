# Its DNS lives outside this repository, so the module makes no records and
# the route keeps its own host rule.
module "arcto_vaultwarden" {
  source = "../modules/service"

  name      = "arcto-vaultwarden"
  namespace = "arcto"
  image     = "vaultwarden/server:testing"

  job_file = format("%s/jobs/arcto/arcto-vaultwarden.nomad.hcl", path.module)
  env      = local.shared_env

  domain = var.domain

  traefik_tags = [
    "traefik.enable=true",
    "traefik.http.routers.arcto-vaultwarden.rule=Host(`vaultwarden.arctopayments.com.au`)",
    "traefik.http.routers.arcto-vaultwarden.entrypoints=websecure",
    "traefik.http.routers.arcto-vaultwarden.tls.certresolver=myresolver",
    "traefik.http.routers.arcto-vaultwarden.service=arcto-vaultwarden",
  ]
}

# The cutover apply forgets the Docker resources without deleting them, so
# docker start brings them back on rollback.
removed {
  from = docker_container.vaultwarden

  lifecycle {
    destroy = false
  }
}

removed {
  from = docker_image.arcto_vaultwarden

  lifecycle {
    destroy = false
  }
}

removed {
  from = docker_network.arcto

  lifecycle {
    destroy = false
  }
}
