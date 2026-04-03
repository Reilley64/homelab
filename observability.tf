module "alloy" {
  source = "./modules/service"

  name     = "jaeger"
  image    = "grafana/alloy:v1.15.0"
  networks = [docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      host_path      = "/var/run/docker.sock"
      container_path = "/var/run/docker.sock"
    },
    {
      host_path      = "/home/${var.username}/homelab/observability/config.alloy"
      container_path = "/etc/alloy/config.alloy"
    },
  ]

  command = [
    "run",
    "--server.http.listen-addr=0.0.0.0:12345",
    "--storage.path=/var/lib/alloy/data",
    "/etc/alloy/config.alloy",
  ]
}

module "loki" {
  source = "./modules/service"

  name     = "loki"
  image    = "grafana/loki:latest"
  networks = [docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      host_path      = "/home/${var.username}/appdata/loki"
      container_path = "/loki"
    },
    {
      host_path      = "/home/${var.username}/homelab/observability/loki.yaml"
      container_path = "/etc/loki/local-config.yaml"
    },
  ]

  command = [
    "-config.file=/etc/loki/local-config.yaml",
  ]
}

module "grafana" {
  source = "./modules/service"

  name     = "grafana"
  image    = "grafana/grafana:latest"
  port     = 3000
  networks = [docker_network.traefik.id]

  env = local.shared_env

  volumes = [
    {
      host_path      = "/home/${var.username}/appdata/grafana"
      container_path = "/var/lib/grafana"
    },
  ]
}
