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
  host_address       = local.host_address
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
}
