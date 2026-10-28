# Its DNS lives outside this repository, so the module makes no records and
# the route keeps its own host rule.
module "arcto_vaultwarden" {
  source = "../modules/service"

  name      = "arcto-vaultwarden"
  namespace = "arcto"
  image     = "vaultwarden/server:testing"

  job_file = format("%s/jobs/arcto/arcto-vaultwarden.nomad.hcl", path.module)
  env      = local.shared_env

  domain       = var.domain
  host_address = local.host_address

  traefik_tags = [
    "traefik.enable=true",
    "traefik.http.routers.arcto-vaultwarden.rule=Host(`vaultwarden.arctopayments.com.au`)",
    "traefik.http.routers.arcto-vaultwarden.entrypoints=websecure",
    "traefik.http.routers.arcto-vaultwarden.tls.certresolver=myresolver",
    "traefik.http.routers.arcto-vaultwarden.service=arcto-vaultwarden",
  ]
}
