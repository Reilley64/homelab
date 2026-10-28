# Its DNS lives outside this repository, so the module makes no records and
# the route keeps its own host rule.
module "arcto_vaultwarden" {
  source = "../modules/service"

  name      = "arcto-vaultwarden"
  namespace = "arcto"
  # The digest of the testing image running today. Nomad never re-pulls a tag.
  image = "vaultwarden/server:testing@sha256:5df6efa7ae56f1d021c830fa90590d054897ccdcc439e4f135905513cec7f647"

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
