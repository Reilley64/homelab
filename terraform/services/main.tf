locals {
  # homelab-1's LAN address. Ansible's inventory holds its own copy.
  host_address = "192.168.86.199"

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

  domain       = var.domain
  host_address = local.host_address
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

  domain       = var.domain
  host_address = local.host_address
}
