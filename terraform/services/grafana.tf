# Grafana's configuration. The job is in observability.tf.
#
# The resources that reach Grafana first depend on module.grafana, so they
# wait for its deployment to be healthy. That takes passing checks for
# min_healthy_time, and Traefik watches Consul, so the route is up by then.

resource "grafana_data_source" "loki" {
  depends_on = [module.grafana]

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
  depends_on = [module.grafana]

  type       = "prometheus"
  name       = "Prometheus"
  uid        = "prometheus"
  url        = "http://prometheus.localdomain"
  is_default = true
}

resource "grafana_data_source" "tempo" {
  depends_on = [module.grafana]

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
  depends_on = [module.grafana]

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
  depends_on = [module.grafana]

  name = "Discord"

  discord {
    url     = var.discord_webhook
    title   = "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}"
    message = "{{ range .Alerts }}{{ if eq .Labels.alertname \"DatasourceError\" }}Could not evaluate {{ .Labels.rulename }}: {{ .Annotations.Error }}{{ else if eq .Labels.alertname \"DatasourceNoData\" }}No data for {{ .Labels.rulename }}{{ else }}{{ .Annotations.summary }}{{ end }}\n{{ end }}"
  }
}

# Every rule is an instant Prometheus query compared with a threshold. A rule
# fires when the query's last value is above or below the threshold for the
# rule's for duration. lookback defaults to 10 minutes.
locals {
  alert_rule_groups = {
    host_disk = {
      name             = "Host disk"
      interval_seconds = 300
      rules = [{
        name          = "Gentoo box low disk space"
        expr          = "node_filesystem_avail_bytes{mountpoint=\"/\"}"
        below         = 53687091200
        for           = "30m"
        no_data_state = "NoData"
        labels        = { severity = "warning" }
        summary       = format("%s has less than 50 GiB free on /", local.host_address)
      }]
    }

    backups = {
      name             = "Backups"
      interval_seconds = 300
      rules = [{
        name          = "Backup is stale"
        expr          = "time() - homelab_backup_last_success_timestamp_seconds"
        above         = 129600
        for           = "15m"
        no_data_state = "Alerting"
        labels        = { severity = "warning" }
        summary       = format("The nightly restic backup to {{ $labels.repository }} has not succeeded for 36 hours. Check `journalctl -u homelab-backup` on %s.", local.host_address)
      }]
    }

    vault = {
      name             = "Vault"
      interval_seconds = 60
      rules = [{
        name = "Vault is sealed"
        # A sealed Vault may stop serving metrics, so a missing series counts
        # as sealed.
        expr          = "max(vault_core_unsealed{job=\"vault\"}) or on() vector(0)"
        below         = 1
        for           = "5m"
        no_data_state = "Alerting"
        labels        = { severity = "critical" }
        summary       = format("Vault on %[1]s is sealed or not reporting metrics, so jobs that read secrets cannot start. It should unseal itself through AWS KMS. Check `journalctl -u vault` on %[1]s.", local.host_address)
      }]
    }

    jellyfin_egress_attribution = {
      name             = "Jellyfin egress attribution"
      interval_seconds = 60
      rules = [
        {
          name          = "Jellyfin session polling failing"
          expr          = "increase(jellyfin_egress_jellyfin_api_failures_total[10m])"
          above         = 0
          for           = "15m"
          no_data_state = "NoData"
          labels        = { severity = "warning" }
          summary       = "observability-agent cannot read Jellyfin /Sessions, so egress is not attributed to users. Check `nomad alloc logs -namespace observability -job observability-agent`."
        },
        {
          name = "Jellyfin egress mostly unattributed"
          # Only evaluated when at least 1 GB left in the hour, so scanners and
          # idle periods don't count.
          expr          = "(sum(increase(jellyfin_user_egress_bytes_v2_total{user=\"unknown\"}[1h])) / sum(increase(jellyfin_user_egress_bytes_v2_total[1h]))) and on() (sum(increase(jellyfin_user_egress_bytes_v2_total[1h])) > 1e9)"
          lookback      = 3600
          above         = 0.5
          for           = "30m"
          no_data_state = "OK"
          labels        = { severity = "warning" }
          summary       = format("Most public Jellyfin egress in the last hour has user=\"unknown\". Check that Jellyfin KnownProxies is %s and that Sessions show real client IPs.", local.jellyfin_known_proxy)
        },
      ]
    }

    public_service_availability = {
      name             = "Public service availability"
      interval_seconds = 60
      rules = [
        for key, service in local.public_services : {
          name          = format("%s public route unavailable", service.display_name)
          expr          = format("probe_success{job=\"blackbox\", service=\"%s\"}", key)
          below         = 1
          for           = "5m"
          no_data_state = "NoData"
          labels        = { service = key, severity = "critical" }
          summary       = format("%s public route is unavailable: %s", service.display_name, service.url)
        }
      ]
    }

    public_service_tls = {
      name             = "Public service TLS"
      interval_seconds = 60
      rules = [
        for key, service in local.public_services : {
          name          = format("%s TLS certificate expires soon", service.display_name)
          expr          = format("(probe_ssl_earliest_cert_expiry{job=\"blackbox\", service=\"%s\"} - time()) / 86400", key)
          below         = 14
          for           = "5m"
          no_data_state = "OK"
          labels        = { service = key, severity = "warning" }
          summary       = format("%s has fewer than 14 days of TLS validity remaining: %s", service.display_name, service.url)
        }
      ]
    }
  }
}

resource "grafana_rule_group" "alerts" {
  for_each = local.alert_rule_groups

  name             = each.value.name
  folder_uid       = grafana_folder.homelab.uid
  interval_seconds = each.value.interval_seconds

  dynamic "rule" {
    for_each = each.value.rules

    content {
      name           = rule.value.name
      condition      = "B"
      for            = rule.value.for
      no_data_state  = rule.value.no_data_state
      exec_err_state = "Error"

      annotations = {
        summary = rule.value.summary
      }

      labels = rule.value.labels

      data {
        ref_id         = "A"
        datasource_uid = grafana_data_source.prometheus.uid

        relative_time_range {
          from = try(rule.value.lookback, 600)
          to   = 0
        }

        model = jsonencode({
          refId         = "A"
          expr          = rule.value.expr
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
            evaluator = can(rule.value.above) ? { type = "gt", params = [rule.value.above] } : { type = "lt", params = [rule.value.below] }
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

moved {
  from = grafana_rule_group.host_disk
  to   = grafana_rule_group.alerts["host_disk"]
}

moved {
  from = grafana_rule_group.backups
  to   = grafana_rule_group.alerts["backups"]
}

moved {
  from = grafana_rule_group.vault
  to   = grafana_rule_group.alerts["vault"]
}

moved {
  from = grafana_rule_group.jellyfin_egress_attribution
  to   = grafana_rule_group.alerts["jellyfin_egress_attribution"]
}

moved {
  from = grafana_rule_group.public_service_availability
  to   = grafana_rule_group.alerts["public_service_availability"]
}

moved {
  from = grafana_rule_group.public_service_tls
  to   = grafana_rule_group.alerts["public_service_tls"]
}

resource "grafana_service_account" "mcp_grafana" {
  depends_on = [module.grafana]

  name = "mcp-grafana"
  role = "Viewer"
}

resource "grafana_service_account_token" "mcp_grafana" {
  name               = "mcp-grafana"
  service_account_id = grafana_service_account.mcp_grafana.id
}
