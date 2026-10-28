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
