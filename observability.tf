resource "docker_network" "observability" {
  name   = "observability"
  driver = "bridge"
}

module "node_exporter" {
  source = "./modules/service"

  name     = "node-exporter"
  image    = "prom/node-exporter:latest"
  networks = [docker_network.observability.id]

  env = local.shared_env

  command = [
    "--path.procfs=/host/proc",
    "--path.sysfs=/host/sys",
    "--path.rootfs=/rootfs",
    "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)",
  ]

  volumes = [
    {
      container_path = "/host/proc"
      host_path      = "/proc"
      read_only      = true
    },
    {
      container_path = "/host/sys"
      host_path      = "/sys"
      read_only      = true
    },
    {
      container_path = "/rootfs"
      host_path      = "/"
      read_only      = true
    },
  ]
}

module "prometheus" {
  source = "./modules/service"

  name     = "prometheus"
  image    = "prom/prometheus:latest"
  port     = 9090
  networks = [docker_network.observability.id, docker_network.traefik.id]

  env  = local.shared_env
  user = "${var.uid}:${var.gid}"

  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.retention.time=30d",
  ]

  uploads = [
    {
      file    = "/etc/prometheus/prometheus.yml"
      content = file("${path.module}/observability/prometheus.yml")
    },
  ]

  volumes = [
    {
      container_path = "/prometheus"
      host_path      = "/home/${var.username}/appdata/prometheus"
    },
  ]
}

module "grafana" {
  source = "./modules/service"

  name     = "grafana"
  image    = "grafana/grafana:latest"
  port     = 3000
  networks = [docker_network.observability.id, docker_network.traefik.id]

  env = concat(local.shared_env, [
    "GF_SECURITY_ADMIN_PASSWORD=${var.password}",
    "GF_SERVER_ROOT_URL=http://grafana.localdomain",
  ])

  user = "${var.uid}:${var.gid}"

  volumes = [
    {
      container_path = "/var/lib/grafana"
      host_path      = "/home/${var.username}/appdata/grafana"
    },
  ]
}

resource "time_sleep" "grafana_ready" {
  depends_on = [module.grafana]

  create_duration = "30s"
}

resource "grafana_data_source" "prometheus" {
  depends_on = [time_sleep.grafana_ready]

  type       = "prometheus"
  name       = "Prometheus"
  uid        = "prometheus"
  url        = "http://prometheus:9090"
  is_default = true
}

resource "grafana_folder" "homelab" {
  depends_on = [time_sleep.grafana_ready]

  title = "Homelab"
}

resource "grafana_dashboard" "jellyfin" {
  folder = grafana_folder.homelab.uid

  config_json = templatefile("${path.module}/observability/jellyfin-dashboard.json.tftpl", {
    datasource_uid = grafana_data_source.prometheus.uid
  })
}
