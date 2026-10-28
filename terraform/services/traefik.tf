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

  domain       = var.domain
  host_address = local.host_address
}
