locals {
  # Jellyfin trusts X-Forwarded-For only from this address (KnownProxies in
  # ~/appdata/jellyfin/network.xml). Docker allocates from the bottom of the
  # subnet, so the top address stays free while Traefik is recreated.
  traefik_ip = "172.22.255.254"
}

resource "docker_network" "traefik" {
  name   = "traefik"
  driver = "bridge"

  ipam_config {
    subnet  = "172.22.0.0/16"
    gateway = "172.22.0.1"
  }
}

module "traefik" {
  source = "./modules/service"

  domain   = var.domain
  name     = "traefik"
  image    = "traefik:latest"
  networks = [docker_network.traefik.id]

  ipv4_addresses = {
    (docker_network.traefik.id) = local.traefik_ip
  }

  ports = [
    {
      internal_port = 80
      external_port = 80
    },
    {
      internal_port = 443
      external_port = 443
    },
    {
      internal_port = 8080
      external_port = 4040
    },
  ]

  env = local.shared_env

  command = [
    "--api.insecure=true",
    "--providers.docker=true",
    "--metrics.prometheus=true",
    "--metrics.prometheus.addRoutersLabels=true",
    "--accesslog=true",
    "--accesslog.filepath=/var/log/traefik/access.json",
    "--accesslog.format=json",
    "--accesslog.fields.defaultmode=drop",
    "--accesslog.fields.names.StartUTC=keep",
    "--accesslog.fields.names.RouterName=keep",
    "--accesslog.fields.names.ClientHost=keep",
    "--accesslog.fields.names.DownstreamContentSize=keep",
    "--accesslog.fields.names.DownstreamStatus=keep",
    "--accesslog.fields.headers.defaultmode=drop",
    "--accesslog.fields.queryparameters.defaultmode=drop",
    "--entrypoints.web.address=:80",
    "--entrypoints.websecure.address=:443",
    "--certificatesresolvers.myresolver.acme.tlschallenge=true",
    "--certificatesresolvers.myresolver.acme.email=reilleygray@gmail.com",
    "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json",
  ]

  volumes = [
    {
      container_path = "/var/run/docker.sock"
      host_path      = "/var/run/docker.sock"
    },
    {
      container_path = "/letsencrypt"
      host_path      = format("/home/%s/appdata/letsencrypt", var.username)
    },
    {
      container_path = "/var/log/traefik"
      host_path      = format("/home/%s/appdata/traefik/log", var.username)
    },
  ]
}
