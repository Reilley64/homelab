locals {
  public_services = {
    bitwarden = {
      display_name = "Bitwarden"
      url          = format("https://bitwarden.%s", var.domain)
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

# --- collectors ---

module "alloy" {
  source = "../modules/service"

  name      = "alloy"
  namespace = "observability"
  image     = "grafana/alloy:v1.21.2"

  job_file = format("%s/jobs/observability/alloy.nomad.hcl", path.module)
  job_vars = {
    user   = format("%s:%s", var.uid, var.gid)
    config = file(format("%s/config/alloy.alloy", path.module))
  }
  env = local.shared_env

  domain = var.domain
}

module "blackbox_exporter" {
  source = "../modules/service"

  name      = "blackbox-exporter"
  namespace = "observability"
  image     = "prom/blackbox-exporter:v0.29.1"

  job_file = format("%s/jobs/observability/blackbox-exporter.nomad.hcl", path.module)
  job_vars = {
    config = file(format("%s/config/blackbox.yml", path.module))
  }
  env = local.shared_env

  domain = var.domain
}

locals {
  observability_agent_context = abspath(format("%s/../../observability", path.module))
  observability_agent_source_hash = sha256(join("", [
    for source_path in sort(concat(["Dockerfile", "go.mod"], tolist(fileset(local.observability_agent_context, "**/*.go")))) :
    format("%s:%s", source_path, filesha256(format("%s/%s", local.observability_agent_context, source_path)))
  ]))
  observability_agent_image_tag = substr(local.observability_agent_source_hash, 0, 12)
}

module "observability_agent" {
  source = "../modules/service"

  name      = "observability-agent"
  namespace = "observability"
  image     = format("observability-agent:%s", local.observability_agent_image_tag)

  # No revision label: it would rebuild the image on every commit to this
  # repository, not only when the agent's source changes.
  build = {
    context = local.observability_agent_context
    labels = {
      "org.opencontainers.image.source"  = "https://github.com/Reilley64/homelab"
      "org.opencontainers.image.version" = local.observability_agent_image_tag
    }
  }

  job_file = format("%s/jobs/observability/observability-agent.nomad.hcl", path.module)
  env      = local.shared_env

  domain = var.domain
}

# Node metrics come from the node_exporter host service that Ansible installs,
# which sees the host's real network interfaces.
removed {
  from = module.node_exporter.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.node_exporter.docker_image.image

  lifecycle {
    destroy = false
  }
}

# --- storage ---

module "loki" {
  source = "../modules/service"

  name      = "loki"
  namespace = "observability"
  image     = "grafana/loki:3.7.9"

  job_file = format("%s/jobs/observability/loki.nomad.hcl", path.module)
  job_vars = {
    user   = format("%s:%s", var.uid, var.gid)
    config = file(format("%s/config/loki.yml", path.module))
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

module "prometheus" {
  source = "../modules/service"

  name      = "prometheus"
  namespace = "observability"
  image     = "prom/prometheus:v3.15.1"

  job_file = format("%s/jobs/observability/prometheus.nomad.hcl", path.module)
  job_vars = {
    user      = format("%s:%s", var.uid, var.gid)
    consul_ca = file(pathexpand("~/.homelab/pki/ca.crt"))
    config = templatefile(format("%s/config/prometheus.yml.tftpl", path.module), {
      public_services = local.public_services
    })
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

module "tempo" {
  source = "../modules/service"

  name      = "tempo"
  namespace = "observability"
  image     = "grafana/tempo:3.1.1"

  job_file = format("%s/jobs/observability/tempo.nomad.hcl", path.module)
  job_vars = {
    user   = format("%s:%s", var.uid, var.gid)
    config = file(format("%s/config/tempo.yml", path.module))
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

# --- grafana ---

module "grafana" {
  source = "../modules/service"

  name      = "grafana"
  namespace = "observability"
  image     = "grafana/grafana:13.2.4"

  job_file = format("%s/jobs/observability/grafana.nomad.hcl", path.module)
  job_vars = {
    user = format("%s:%s", var.uid, var.gid)
  }
  env = local.shared_env

  domain  = var.domain
  traefik = true
}

# The cutover apply forgets the Docker resources without deleting them, so
# docker start brings them back on rollback.
removed {
  from = module.alloy.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.alloy.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.blackbox_exporter.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.blackbox_exporter.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.observability_agent.docker_container.container

  lifecycle {
    destroy = false
  }
}

moved {
  from = module.observability_agent.docker_image.image
  to   = module.observability_agent.docker_image.build[0]
}

removed {
  from = module.loki.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.loki.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.prometheus.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.prometheus.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.tempo.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.tempo.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.grafana.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.grafana.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.mcp_grafana.docker_container.container

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.mcp_grafana.docker_image.image

  lifecycle {
    destroy = false
  }
}

removed {
  from = docker_network.observability

  lifecycle {
    destroy = false
  }
}

# The job is healthy when the module returns, but Traefik needs a moment to
# pick the route up from Consul before the Grafana provider can reach it.
resource "time_sleep" "grafana_ready" {
  create_duration = "30s"

  triggers = {
    jobspec = sha256(module.grafana.jobspec)
  }
}

resource "grafana_data_source" "loki" {
  depends_on = [time_sleep.grafana_ready]

  type = "loki"
  name = "Loki"
  uid  = "loki"
  url  = "http://loki.localdomain"

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
  url        = "http://prometheus.localdomain"
  is_default = true
}

resource "grafana_data_source" "tempo" {
  depends_on = [time_sleep.grafana_ready]

  type = "tempo"
  name = "Tempo"
  uid  = "tempo"
  url  = "http://tempo.localdomain"

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

  config_json = templatefile(format("%s/config/jellyfin-dashboard.json.tftpl", path.module), {
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

resource "grafana_rule_group" "backups" {
  name             = "Backups"
  folder_uid       = grafana_folder.homelab.uid
  interval_seconds = 300

  rule {
    name           = "Backup is stale"
    condition      = "B"
    for            = "15m"
    no_data_state  = "Alerting"
    exec_err_state = "Error"

    annotations = {
      summary = "The nightly restic backup to {{ $labels.repository }} has not succeeded for 36 hours. Check `journalctl -u homelab-backup` on 192.168.86.199."
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
        expr          = "time() - homelab_backup_last_success_timestamp_seconds"
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
          evaluator = { type = "gt", params = [129600] }
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

resource "grafana_rule_group" "vault" {
  name             = "Vault"
  folder_uid       = grafana_folder.homelab.uid
  interval_seconds = 60

  rule {
    name           = "Vault is sealed"
    condition      = "B"
    for            = "5m"
    no_data_state  = "Alerting"
    exec_err_state = "Error"

    annotations = {
      summary = "Vault on 192.168.86.199 is sealed or not reporting metrics, so jobs that read secrets cannot start. It should unseal itself through AWS KMS. Check `journalctl -u vault` on 192.168.86.199."
    }

    labels = {
      severity = "critical"
    }

    data {
      ref_id         = "A"
      datasource_uid = grafana_data_source.prometheus.uid

      relative_time_range {
        from = 600
        to   = 0
      }

      # A sealed Vault may stop serving metrics, so a missing series counts
      # as sealed.
      model = jsonencode({
        refId         = "A"
        expr          = "max(vault_core_unsealed{job=\"vault\"}) or on() vector(0)"
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
      summary = "observability-agent cannot read Jellyfin /Sessions, so egress is not attributed to users. Check `nomad alloc logs -namespace observability -job observability-agent`."
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
      summary = format("Most public Jellyfin egress in the last hour has user=\"unknown\". Check that Jellyfin KnownProxies is %s and that Sessions show real client IPs.", local.jellyfin_known_proxy)
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
  source = "../modules/service"

  name      = "mcp-grafana"
  namespace = "observability"
  image     = "grafana/mcp-grafana:2.1.1"

  job_file = format("%s/jobs/observability/mcp-grafana.nomad.hcl", path.module)
  env      = local.shared_env

  domain  = var.domain
  traefik = true
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

# Read once to write kv/observability/mcp-grafana in Vault.
output "mcp_grafana_service_account_token" {
  value     = grafana_service_account_token.mcp_grafana.key
  sensitive = true
}
