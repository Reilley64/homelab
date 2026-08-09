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

module "loki" {
  source = "./modules/service"

  name     = "loki"
  image    = "grafana/loki:latest"
  port     = 3100
  networks = [docker_network.observability.id, docker_network.traefik.id]

  env  = local.shared_env
  user = "${var.uid}:${var.gid}"

  command = [
    "-config.file=/etc/loki/loki.yml",
  ]

  uploads = [
    {
      file    = "/etc/loki/loki.yml"
      content = file("${path.module}/observability/loki.yml")
    },
  ]

  volumes = [
    {
      container_path = "/loki"
      host_path      = "/home/${var.username}/appdata/loki"
    },
  ]
}

module "alloy" {
  source = "./modules/service"

  name     = "alloy"
  image    = "grafana/alloy:latest"
  networks = [docker_network.observability.id]

  env  = local.shared_env
  user = "${var.uid}:${var.gid}"

  # ponytail: /var/lib/alloy is drwxrwx--- alloy:alloy in the image, so uid 1000
  # can't reach a mount underneath it.
  command = [
    "run",
    "/etc/alloy/config.alloy",
    "--storage.path=/alloy",
  ]

  uploads = [
    {
      file    = "/etc/alloy/config.alloy"
      content = file("${path.module}/observability/alloy.alloy")
    },
  ]

  volumes = [
    {
      container_path = "/alloy"
      host_path      = "/home/${var.username}/appdata/alloy"
    },
    {
      container_path = "/logs"
      host_path      = "/home/${var.username}/appdata/jellyfin/log"
      read_only      = true
    },
  ]
}

module "jellyfin_egress_exporter" {
  source = "./modules/service"

  name     = "jellyfin-egress-exporter"
  image    = "python:3.13-alpine"
  networks = [docker_network.media.id, docker_network.observability.id]

  env = concat(local.shared_env, [
    "JELLYFIN_URL=http://jellyfin:8096",
    "JELLYFIN_API_KEY=${var.jellyfin_api_key}",
    "ACCESS_LOG_PATH=/logs/access.json",
    "CHECKPOINT_PATH=/state/checkpoint.json",
    "MAPPING_TTL_SECONDS=600",
    "SESSION_POLL_SECONDS=15",
    "METRICS_PORT=9101",
  ])

  command = ["python", "/usr/local/bin/jellyfin-egress-exporter.py"]

  uploads = [{
    file    = "/usr/local/bin/jellyfin-egress-exporter.py"
    content = file("${path.module}/observability/jellyfin_egress_exporter.py")
  }]

  volumes = [
    {
      container_path = "/logs"
      host_path      = "/home/${var.username}/appdata/traefik/log"
      read_only      = true
    },
    {
      container_path = "/state"
      host_path      = "/home/${var.username}/appdata/jellyfin-egress-exporter"
    },
  ]
}

module "traefik_access_log_rotator" {
  source = "./modules/service"

  name     = "traefik-access-log-rotator"
  image    = "python:3.13-alpine"
  networks = []

  env = concat(local.shared_env, [
    "ACCESS_LOG_PATH=/logs/access.json",
    "LOG_MAX_BYTES=104857600",
    "LOG_COPIES=7",
    "ROTATION_CHECK_SECONDS=60",
  ])

  command = ["python", "/usr/local/bin/traefik-access-log-rotator.py"]

  uploads = [{
    file    = "/usr/local/bin/traefik-access-log-rotator.py"
    content = file("${path.module}/observability/traefik_access_log_rotator.py")
  }]

  volumes = [{
    container_path = "/logs"
    host_path      = "/home/${var.username}/appdata/traefik/log"
  }]
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

resource "grafana_data_source" "loki" {
  depends_on = [time_sleep.grafana_ready]

  type = "loki"
  name = "Loki"
  uid  = "loki"
  url  = "http://loki:3100"
}

resource "grafana_service_account" "claude" {
  depends_on = [time_sleep.grafana_ready]

  name = "claude"
  role = "Viewer"
}

resource "grafana_service_account_token" "claude" {
  name               = "claude"
  service_account_id = grafana_service_account.claude.id
}

resource "local_sensitive_file" "grafana_token" {
  filename        = "${path.module}/.grafana-token"
  content         = grafana_service_account_token.claude.key
  file_permission = "0600"
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

resource "grafana_contact_point" "discord" {
  depends_on = [time_sleep.grafana_ready]

  name = "Discord"

  discord {
    url     = var.discord_webhook
    title   = "{{ .CommonLabels.alertname }}"
    message = "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}"
  }
}

resource "grafana_rule_group" "host_disk" {
  name             = "Host disk"
  folder_uid       = grafana_folder.homelab.uid
  interval_seconds = 300

  rule {
    name           = "Gentoo box low disk space"
    condition      = "B"
    for            = "15m"
    no_data_state  = "NoData"
    exec_err_state = "Alerting"

    annotations = {
      summary = "192.168.86.199 has less than 104 GiB free on /"
    }

    labels = {
      severity = "warning"
    }

    data {
      ref_id         = "A"
      datasource_uid = grafana_data_source.prometheus.uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        expr          = "node_filesystem_avail_bytes{mountpoint=\"/\"}"
        instant       = true
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    data {
      ref_id         = "B"
      datasource_uid = "-100"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId = "B"
        type  = "classic_conditions"
        datasource = {
          type = "__expr__"
          uid  = "-100"
        }
        conditions = [{
          evaluator = { type = "lt", params = [111669149696] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
          type      = "query"
        }]
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    notification_settings {
      contact_point = grafana_contact_point.discord.name
    }
  }
}
