locals {
  public_services = {
    bitwarden = {
      display_name = "Bitwarden"
      url          = format("https://bitwarden.%s", var.domain)
    }
    immich = {
      display_name = "Immich"
      url          = format("https://immich.%s", var.domain)
    }
    jellyfin = {
      display_name = "Jellyfin"
      url          = format("https://jellyfin.%s", var.domain)
    }
    seerr = {
      display_name = "Seerr"
      url          = format("https://seerr.%s", var.domain)
    }
    tabletop = {
      display_name = "Tabletop"
      url          = format("https://tabletop.%s/health", var.domain)
    }
  }
}

resource "docker_network" "observability" {
  name   = "observability"
  driver = "bridge"
}

# --- collectors ---

module "alloy" {
  source = "./modules/service"

  domain   = var.domain
  name     = "alloy"
  image    = "grafana/alloy:latest"
  networks = [docker_network.observability.id]

  env  = local.shared_env
  user = format("%s:%s", var.uid, var.gid)

  command = [
    "run",
    "/etc/alloy/config.alloy",
    "--storage.path=/alloy",
  ]

  uploads = [
    {
      file    = "/etc/alloy/config.alloy"
      content = file(format("%s/observability/alloy.alloy", path.module))
    },
  ]

  volumes = [
    {
      container_path = "/alloy"
      host_path      = format("/home/%s/appdata/alloy", var.username)
    },
    {
      container_path = "/logs"
      host_path      = format("/home/%s/appdata/jellyfin/log", var.username)
      read_only      = true
    },
  ]
}

module "blackbox_exporter" {
  source = "./modules/service"

  domain   = var.domain
  name     = "blackbox-exporter"
  image    = "prom/blackbox-exporter:latest"
  networks = [docker_network.observability.id]

  env = local.shared_env

  command = [
    "--config.file=/etc/blackbox_exporter/config.yml",
  ]

  uploads = [
    {
      file    = "/etc/blackbox_exporter/config.yml"
      content = file(format("%s/observability/blackbox.yml", path.module))
    },
  ]
}

module "node_exporter" {
  source = "./modules/service"

  domain   = var.domain
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

module "observability_agent" {
  source = "./modules/service"

  domain   = var.domain
  name     = "observability-agent"
  image    = "observability-agent"
  networks = [docker_network.media.id, docker_network.observability.id]

  build = {
    context = abspath(format("%s/observability", path.module))
    triggers = {
      source = sha256(join("", [
        for source_path in sort(concat(["Dockerfile", "go.mod"], tolist(fileset(format("%s/observability", path.module), "**/*.go")))) :
        format("%s:%s", source_path, filesha256(format("%s/observability/%s", path.module, source_path)))
      ]))
    }
  }

  env = concat(local.shared_env, [
    "JELLYFIN_URL=http://jellyfin:8096",
    format("JELLYFIN_API_KEY=%s", var.jellyfin_api_key),
    "ACCESS_LOG_PATH=/logs/access.json",
    "CHECKPOINT_PATH=/state/checkpoint.json",
    "MAPPING_TTL_SECONDS=600",
    "SESSION_POLL_SECONDS=15",
    "METRICS_PORT=9101",
    "LOG_MAX_BYTES=104857600",
    "LOG_COPIES=7",
    "ROTATION_CHECK_SECONDS=60",
  ])

  volumes = [
    {
      container_path = "/logs"
      host_path      = format("/home/%s/appdata/traefik/log", var.username)
    },
    {
      container_path = "/state"
      host_path      = format("/home/%s/appdata/jellyfin-egress-exporter", var.username)
    },
  ]
}

# --- storage ---

module "loki" {
  source = "./modules/service"

  domain   = var.domain
  name     = "loki"
  image    = "grafana/loki:latest"
  port     = 3100
  networks = [docker_network.observability.id, docker_network.traefik.id]

  env  = local.shared_env
  user = format("%s:%s", var.uid, var.gid)

  command = [
    "-config.file=/etc/loki/loki.yml",
  ]

  uploads = [
    {
      file    = "/etc/loki/loki.yml"
      content = file(format("%s/observability/loki.yml", path.module))
    },
  ]

  volumes = [
    {
      container_path = "/loki"
      host_path      = format("/home/%s/appdata/loki", var.username)
    },
  ]
}

module "prometheus" {
  source = "./modules/service"

  domain   = var.domain
  name     = "prometheus"
  image    = "prom/prometheus:latest"
  port     = 9090
  networks = [docker_network.observability.id, docker_network.traefik.id]

  env  = local.shared_env
  user = format("%s:%s", var.uid, var.gid)

  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.retention.time=30d",
    "--web.enable-otlp-receiver",
  ]

  uploads = [
    {
      file = "/etc/prometheus/prometheus.yml"
      content = templatefile(format("%s/observability/prometheus.yml.tftpl", path.module), {
        public_services = local.public_services
      })
    },
  ]

  volumes = [
    {
      container_path = "/prometheus"
      host_path      = format("/home/%s/appdata/prometheus", var.username)
    },
  ]
}

module "tempo" {
  source = "./modules/service"

  domain   = var.domain
  name     = "tempo"
  image    = "grafana/tempo:latest"
  networks = [docker_network.observability.id]

  env  = local.shared_env
  user = format("%s:%s", var.uid, var.gid)

  command = [
    "-config.file=/etc/tempo/tempo.yml",
  ]

  uploads = [
    {
      file    = "/etc/tempo/tempo.yml"
      content = file(format("%s/observability/tempo.yml", path.module))
    },
  ]

  volumes = [
    {
      container_path = "/var/tempo"
      host_path      = format("/home/%s/appdata/tempo", var.username)
    },
  ]
}

# --- grafana ---

module "grafana" {
  source = "./modules/service"

  domain   = var.domain
  name     = "grafana"
  image    = "grafana/grafana:latest"
  port     = 3000
  networks = [docker_network.observability.id, docker_network.traefik.id]

  env = concat(local.shared_env, [
    format("GF_SECURITY_ADMIN_PASSWORD=%s", var.password),
    "GF_SERVER_ROOT_URL=http://grafana.localdomain",
    "GF_PLUGINS_PREINSTALL=marcusolsson-dynamictext-panel@6.3.0",
  ])

  user = format("%s:%s", var.uid, var.gid)

  volumes = [
    {
      container_path = "/var/lib/grafana"
      host_path      = format("/home/%s/appdata/grafana", var.username)
    },
  ]
}

resource "time_sleep" "grafana_ready" {
  create_duration = "30s"

  triggers = {
    container_id = module.grafana.id
  }
}

resource "grafana_data_source" "loki" {
  depends_on = [time_sleep.grafana_ready]

  type = "loki"
  name = "Loki"
  uid  = "loki"
  url  = "http://loki:3100"

  # Loki keeps an OTLP record's trace id as structured metadata, so match the
  # field by name rather than a regex over the line. A literal uid, because
  # the Tempo data source already points back here.
  json_data_encoded = jsonencode({
    derivedFields = [{
      name            = "trace_id"
      matcherType     = "label"
      matcherRegex    = "trace_id"
      datasourceUid   = "tempo"
      url             = "$${__value.raw}"
      urlDisplayLabel = "Open trace"
    }]
  })
}

resource "grafana_data_source" "prometheus" {
  depends_on = [time_sleep.grafana_ready]

  type       = "prometheus"
  name       = "Prometheus"
  uid        = "prometheus"
  url        = "http://prometheus:9090"
  is_default = true
}

resource "grafana_data_source" "tempo" {
  depends_on = [time_sleep.grafana_ready]

  type = "tempo"
  name = "Tempo"
  uid  = "tempo"
  url  = "http://tempo:3200"

  json_data_encoded = jsonencode({
    tracesToLogsV2 = {
      datasourceUid      = grafana_data_source.loki.uid
      spanStartTimeShift = "-5m"
      spanEndTimeShift   = "5m"
      tags               = [{ key = "service.name", value = "service_name" }]
      customQuery        = true
      query              = "{$${__tags}} | trace_id=\"$${__trace.traceId}\""
    }
  })
}

resource "grafana_folder" "homelab" {
  depends_on = [time_sleep.grafana_ready]

  title = "Homelab"
}

resource "grafana_dashboard" "jellyfin" {
  folder = grafana_folder.homelab.uid

  config_json = templatefile(format("%s/observability/jellyfin-dashboard.json.tftpl", path.module), {
    datasource_uid = grafana_data_source.prometheus.uid
  })
}

# --- alerting ---

resource "grafana_contact_point" "discord" {
  depends_on = [time_sleep.grafana_ready]

  name = "Discord"

  discord {
    url     = var.discord_webhook
    title   = "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}"
    message = "{{ range .Alerts }}{{ if eq .Labels.alertname \"DatasourceError\" }}Could not evaluate {{ .Labels.rulename }}: {{ .Annotations.Error }}{{ else if eq .Labels.alertname \"DatasourceNoData\" }}No data for {{ .Labels.rulename }}{{ else }}{{ .Annotations.summary }}{{ end }}\n{{ end }}"
  }
}

resource "grafana_rule_group" "host_disk" {
  name             = "Host disk"
  folder_uid       = grafana_folder.homelab.uid
  interval_seconds = 300

  rule {
    name           = "Gentoo box low disk space"
    condition      = "B"
    for            = "30m"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    annotations = {
      summary = "192.168.86.199 has less than 50 GiB free on /"
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
          evaluator = { type = "lt", params = [53687091200] }
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

resource "grafana_rule_group" "jellyfin_egress_attribution" {
  name             = "Jellyfin egress attribution"
  folder_uid       = grafana_folder.homelab.uid
  interval_seconds = 60

  rule {
    name           = "Jellyfin session polling failing"
    condition      = "B"
    for            = "15m"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    annotations = {
      summary = "observability-agent cannot read Jellyfin /Sessions, so egress is not attributed to users. Check `docker logs observability-agent`."
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
        expr          = "increase(jellyfin_egress_jellyfin_api_failures_total[10m])"
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
          evaluator = { type = "gt", params = [0] }
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

  rule {
    name           = "Jellyfin egress mostly unattributed"
    condition      = "B"
    for            = "30m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary = format("Most public Jellyfin egress in the last hour has user=\"unknown\". Check that Jellyfin KnownProxies is %s and that Sessions show real client IPs.", local.traefik_ip)
    }

    labels = {
      severity = "warning"
    }

    data {
      ref_id         = "A"
      datasource_uid = grafana_data_source.prometheus.uid

      relative_time_range {
        from = 3600
        to   = 0
      }

      # Only evaluated when at least 1 GB left in the hour, so scanners and
      # idle periods don't count.
      model = jsonencode({
        refId         = "A"
        expr          = "(sum(increase(jellyfin_user_egress_bytes_v2_total{user=\"unknown\"}[1h])) / sum(increase(jellyfin_user_egress_bytes_v2_total[1h]))) and on() (sum(increase(jellyfin_user_egress_bytes_v2_total[1h])) > 1e9)"
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
          evaluator = { type = "gt", params = [0.5] }
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

resource "grafana_rule_group" "public_service_availability" {
  name             = "Public service availability"
  folder_uid       = grafana_folder.homelab.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.public_services

    content {
      name           = format("%s public route unavailable", rule.value.display_name)
      condition      = "B"
      for            = "5m"
      no_data_state  = "NoData"
      exec_err_state = "Error"

      annotations = {
        summary = format("%s public route is unavailable: %s", rule.value.display_name, rule.value.url)
      }

      labels = {
        service  = rule.key
        severity = "critical"
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
          expr          = format("probe_success{job=\"blackbox\", service=\"%s\"}", rule.key)
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
            evaluator = { type = "lt", params = [1] }
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
}

resource "grafana_rule_group" "public_service_tls" {
  name             = "Public service TLS"
  folder_uid       = grafana_folder.homelab.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.public_services

    content {
      name           = format("%s TLS certificate expires soon", rule.value.display_name)
      condition      = "B"
      for            = "5m"
      no_data_state  = "OK"
      exec_err_state = "Error"

      annotations = {
        summary = format("%s has fewer than 14 days of TLS validity remaining: %s", rule.value.display_name, rule.value.url)
      }

      labels = {
        service  = rule.key
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
          expr          = format("(probe_ssl_earliest_cert_expiry{job=\"blackbox\", service=\"%s\"} - time()) / 86400", rule.key)
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
            evaluator = { type = "lt", params = [14] }
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
}

# --- grafana mcp ---

module "mcp_grafana" {
  source = "./modules/service"

  domain   = var.domain
  name     = "mcp-grafana"
  image    = "grafana/mcp-grafana:latest"
  port     = 8000
  networks = [docker_network.observability.id, docker_network.traefik.id]

  env = concat(local.shared_env, [
    "GRAFANA_URL=http://grafana:3000",
    format("GRAFANA_SERVICE_ACCOUNT_TOKEN=%s", grafana_service_account_token.mcp_grafana.key),
    format("MCP_GRAFANA_SERVER_TOKEN=%s", random_password.mcp_grafana_caller_token.result),
  ])

  command = [
    "--transport=streamable-http",
    "--allowed-hosts=mcp-grafana.localdomain",
    "--disable-write",
  ]
}

resource "grafana_service_account" "mcp_grafana" {
  depends_on = [time_sleep.grafana_ready]

  name = "mcp-grafana"
  role = "Viewer"
}

resource "grafana_service_account_token" "mcp_grafana" {
  name               = "mcp-grafana"
  service_account_id = grafana_service_account.mcp_grafana.id
}

resource "random_password" "mcp_grafana_caller_token" {
  length  = 48
  special = false
}

output "mcp_grafana_caller_token" {
  value     = random_password.mcp_grafana_caller_token.result
  sensitive = true
}
