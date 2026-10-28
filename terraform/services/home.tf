# Home Assistant runs on its own device, the Home Assistant Green. Consul lists
# it as an external node so Traefik can route to it. External nodes have no
# agent to run health checks, so the service has none.
resource "consul_node" "homeassistant_green" {
  name    = "homeassistant-green"
  address = "192.168.86.139"

  meta = {
    "external-node" = "true"
  }
}

resource "consul_service" "homeassistant" {
  name = "homeassistant"
  node = consul_node.homeassistant_green.name
  port = 8123

  tags = [
    "traefik.enable=true",
    format("traefik.http.routers.homeassistant.rule=Host(`homeassistant.%s`)", var.domain),
    "traefik.http.routers.homeassistant.entrypoints=websecure",
    "traefik.http.routers.homeassistant.tls.certresolver=myresolver",
    "traefik.http.routers.homeassistant.service=homeassistant",
  ]
}

module "piper" {
  source = "../modules/service"

  name      = "piper"
  namespace = "home"
  image     = "rhasspy/wyoming-piper:2.1.2"

  job_file = format("%s/jobs/home/piper.nomad.hcl", path.module)
  env      = local.shared_env

  domain    = var.domain
  local_dns = true
}
