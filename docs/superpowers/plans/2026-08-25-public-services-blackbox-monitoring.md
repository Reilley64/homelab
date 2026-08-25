# Public Services Blackbox Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-network HTTPS probes for all five public services, service-specific Discord alerts, and a combined Public Services/Jellyfin Grafana dashboard.

**Architecture:** A Blackbox Exporter container on the observability network will probe repository-defined public HTTPS targets on Prometheus's behalf every 60 seconds. Prometheus metrics feed Grafana-managed availability and TLS alerts plus an all-service overview placed above the existing Jellyfin panels.

**Tech Stack:** Terraform 1.15, `grafana/grafana` provider 4.45, Docker provider, Prometheus, Prometheus Blackbox Exporter, Grafana dashboard JSON, Python standard-library `unittest` fixtures.

**Spec:** `docs/superpowers/specs/2026-08-25-public-services-blackbox-monitoring-design.md`

## Global Constraints

- Probe exactly Jellyfin, Seerr, Immich, Bitwarden, and Foundry through `https://<service>.${var.domain}`.
- Run probes inside the homelab; do not claim independent external-network coverage.
- Probe every 60 seconds with a 10-second module timeout, redirects enabled, final `2xx` required, TLS required, and IPv4 preferred.
- Use no application credentials, API keys, private endpoints, raw `docker_container` resources, or Grafana Cloud resources.
- Alert through the existing Discord contact point after five minutes of continuous failure and when TLS validity falls below 14 days.
- Keep the dashboard UID `jellyfin`, rename its title to `Public Services`, and preserve all six existing Jellyfin panels.
- Put the existing Jellyfin panels beneath a collapsible `Jellyfin details` row that starts expanded.
- Preserve every pre-existing staged and unstaged workspace change. Stage only feature hunks and review `git diff --cached` before every commit.
- Do not run `terraform apply`; stop after producing and reviewing a plan.
- Current documentation references: `/prometheus/blackbox_exporter`, `/grafana/terraform-provider-grafana`, and `/grafana/grafana`.

---

### Task 1: Add the probe container and Prometheus scrape path

**Files:**
- Create: `tests/observability/fixtures/public-services.json`
- Create: `tests/observability/test_public_services.py`
- Create: `observability/blackbox.yml`
- Rename: `observability/prometheus.yml` to `observability/prometheus.yml.tftpl`
- Modify: `observability.tf:1-73`

**Interfaces:**
- Consumes: `var.domain`, `local.shared_env`, `docker_network.observability`, and the existing `modules/service` contract.
- Produces: `local.public_services` as `map(object({ display_name = string, url = string }))`, the `https_2xx` Blackbox module, Prometheus job `blackbox`, exporter-health job `blackbox-exporter`, and metrics labeled with `service` and `service_name`.

- [ ] **Step 1: Record the dirty-worktree baseline before editing**

Run:

```bash
git status --short
git diff -- observability.tf observability/prometheus.yml observability/jellyfin-dashboard.json.tftpl > /tmp/public-services-preexisting.patch
git diff --cached --name-only > /tmp/public-services-preexisting-staged.txt
```

Expected: the existing unrelated changes remain visible; `/tmp/public-services-preexisting.patch` records the pre-task state of overlapping files.

- [ ] **Step 2: Create the target scenario fixture**

Create `tests/observability/fixtures/public-services.json`:

```json
{
  "services": {
    "bitwarden": {
      "display_name": "Bitwarden",
      "url": "https://bitwarden.example.test"
    },
    "foundry": {
      "display_name": "Foundry",
      "url": "https://foundry.example.test"
    },
    "immich": {
      "display_name": "Immich",
      "url": "https://immich.example.test"
    },
    "jellyfin": {
      "display_name": "Jellyfin",
      "url": "https://jellyfin.example.test"
    },
    "seerr": {
      "display_name": "Seerr",
      "url": "https://seerr.example.test"
    }
  }
}
```

- [ ] **Step 3: Write failing configuration tests**

Create `tests/observability/test_public_services.py`:

```python
import json
from pathlib import Path
import subprocess
import unittest


REPO = Path(__file__).resolve().parents[2]
FIXTURE = "tests/observability/fixtures/public-services.json"


def terraform_json(expression: str):
    result = subprocess.run(
        ["terraform", "console"],
        cwd=REPO,
        input=f"jsonencode({expression})\n",
        capture_output=True,
        text=True,
        check=True,
    )
    encoded = json.loads(result.stdout.strip().splitlines()[-1])
    return json.loads(encoded)


class ProbeConfigurationTest(unittest.TestCase):
    def test_blackbox_https_module(self):
        config = terraform_json(
            'yamldecode(file("observability/blackbox.yml"))'
        )
        module = config["modules"]["https_2xx"]

        self.assertEqual(module["prober"], "http")
        self.assertEqual(module["timeout"], "10s")
        self.assertEqual(module["http"]["valid_status_codes"], [])
        self.assertTrue(module["http"]["follow_redirects"])
        self.assertTrue(module["http"]["fail_if_not_ssl"])
        self.assertEqual(module["http"]["preferred_ip_protocol"], "ip4")

    def test_prometheus_keeps_existing_jobs_and_adds_all_probes(self):
        config = terraform_json(
            'yamldecode(templatefile("observability/prometheus.yml.tftpl", {'
            f' public_services = jsondecode(file("{FIXTURE}")).services '
            '}))'
        )
        jobs = {job["job_name"]: job for job in config["scrape_configs"]}

        self.assertTrue(
            {"traefik", "node", "jellyfin-egress", "prometheus"}
            <= set(jobs)
        )
        self.assertEqual(jobs["blackbox"]["scrape_interval"], "60s")
        self.assertEqual(jobs["blackbox"]["scrape_timeout"], "15s")
        self.assertEqual(jobs["blackbox"]["params"]["module"], ["https_2xx"])
        self.assertEqual(
            jobs["blackbox-exporter"]["static_configs"][0]["targets"],
            ["blackbox-exporter:9115"],
        )

        checks = {
            config["labels"]["service"]: (
                config["labels"]["service_name"],
                config["targets"][0],
            )
            for config in jobs["blackbox"]["static_configs"]
        }
        fixture = json.loads((REPO / FIXTURE).read_text())["services"]
        expected = {
            key: (service["display_name"], service["url"])
            for key, service in fixture.items()
        }
        self.assertEqual(checks, expected)

        relabeling = jobs["blackbox"]["relabel_configs"]
        self.assertEqual(relabeling[0]["target_label"], "__param_target")
        self.assertEqual(relabeling[1]["target_label"], "instance")
        self.assertEqual(relabeling[2]["replacement"], "blackbox-exporter:9115")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4: Run the new tests and verify the expected failure**

Run:

```bash
python3 -m unittest tests/observability/test_public_services.py -v
```

Expected: both tests error because `observability/blackbox.yml` and `observability/prometheus.yml.tftpl` do not exist.

- [ ] **Step 5: Add the Blackbox Exporter module configuration**

Create `observability/blackbox.yml`:

```yaml
modules:
  https_2xx:
    prober: http
    timeout: 10s
    http:
      valid_status_codes: []
      method: GET
      follow_redirects: true
      fail_if_not_ssl: true
      preferred_ip_protocol: ip4
```

- [ ] **Step 6: Convert the Prometheus configuration to a target template**

Run:

```bash
git mv observability/prometheus.yml observability/prometheus.yml.tftpl
```

Keep the four existing scrape jobs unchanged, then append these jobs to `scrape_configs`:

```yaml
  - job_name: blackbox
    scrape_interval: 60s
    scrape_timeout: 15s
    metrics_path: /probe
    params:
      module: [https_2xx]
    static_configs:
%{ for key, service in public_services ~}
      - targets: ["${service.url}"]
        labels:
          service: "${key}"
          service_name: "${service.display_name}"
%{ endfor ~}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115

  - job_name: blackbox-exporter
    static_configs:
      - targets: ["blackbox-exporter:9115"]
```

- [ ] **Step 7: Define the service inventory and exporter container**

Immediately after `docker_network.observability`, add to `observability.tf`:

```hcl
locals {
  public_services = {
    bitwarden = {
      display_name = "Bitwarden"
      url          = format("https://bitwarden.%s", var.domain)
    }
    foundry = {
      display_name = "Foundry"
      url          = format("https://foundry.%s", var.domain)
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
  }
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
```

Replace the Prometheus upload's `content` expression with:

```hcl
content = templatefile(format("%s/observability/prometheus.yml.tftpl", path.module), {
  public_services = local.public_services
})
```

- [ ] **Step 8: Run focused configuration tests**

Run:

```bash
python3 -m unittest tests/observability/test_public_services.py -v
terraform fmt -check
terraform validate
```

Expected: two unit tests pass, formatting passes, and Terraform reports `Success! The configuration is valid.`

- [ ] **Step 9: Validate Blackbox Exporter's configuration parser**

Run the check on the same remote Docker host Terraform uses:

```bash
ssh "$(terraform console <<<'var.username' | tr -d '"')@192.168.86.199"   'docker run --rm -i prom/blackbox-exporter:latest --config.file=/dev/stdin --config.check'   < observability/blackbox.yml
```

Expected output contains `Config file is ok exiting...` and the command exits with status 0.

- [ ] **Step 10: Commit only Task 1 feature hunks**

Run:

```bash
git add tests/observability/fixtures/public-services.json   tests/observability/test_public_services.py   observability/blackbox.yml   observability/prometheus.yml   observability/prometheus.yml.tftpl
git add -p observability.tf
git diff --cached --check
git diff --cached
```

For `git add -p observability.tf`, stage only `local.public_services`, `module.blackbox_exporter`, and the Prometheus `templatefile` change. Reject pre-existing format-only hunks recorded in `/tmp/public-services-preexisting.patch`.

Commit after the cached diff contains no unrelated changes:

```bash
git commit -m "Add public service blackbox probes"
```

---

### Task 2: Add service-specific availability and TLS alerts

**Files:**
- Modify: `tests/observability/test_public_services.py`
- Modify: `observability.tf:after grafana_rule_group.host_disk`

**Interfaces:**
- Consumes: `local.public_services`, `grafana_data_source.prometheus.uid`, `grafana_folder.homelab.uid`, and `grafana_contact_point.discord.name`.
- Produces: `grafana_rule_group.public_service_availability` and `grafana_rule_group.public_service_tls`, each with one rule per service.

- [ ] **Step 1: Add a failing source-contract test for the alert resources**

Add this method to `ProbeConfigurationTest`:

```python
    def test_alert_rules_use_shared_inventory_and_required_thresholds(self):
        source = (REPO / "observability.tf").read_text()

        self.assertIn(
            'resource "grafana_rule_group" "public_service_availability"',
            source,
        )
        self.assertIn(
            'resource "grafana_rule_group" "public_service_tls"',
            source,
        )
        self.assertEqual(source.count("for_each = local.public_services"), 2)
        self.assertIn('for            = "5m"', source)
        self.assertIn('no_data_state  = "Alerting"', source)
        self.assertIn('params = [14]', source)
        self.assertIn('severity = "critical"', source)
        self.assertIn('severity = "warning"', source)
```

- [ ] **Step 2: Run the alert contract test and verify it fails**

Run:

```bash
python3 -m unittest   tests.observability.test_public_services.ProbeConfigurationTest.test_alert_rules_use_shared_inventory_and_required_thresholds   -v
```

Expected: FAIL because neither `grafana_rule_group` resource exists.

- [ ] **Step 3: Add availability rules**

Append this resource after the existing host-disk rule group in `observability.tf`:

```hcl
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
      no_data_state  = "Alerting"
      exec_err_state = "Alerting"

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
```

- [ ] **Step 4: Add TLS-expiry rules**

Append:

```hcl
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
      exec_err_state = "Alerting"

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
```

- [ ] **Step 5: Validate the tests, HCL, and provider schema**

Run:

```bash
python3 -m unittest tests/observability/test_public_services.py -v
terraform fmt -check
terraform validate
```

Expected: all tests pass and Terraform validates both dynamic rule blocks against Grafana provider 4.45.

- [ ] **Step 6: Commit only Task 2 feature hunks**

Run:

```bash
git add tests/observability/test_public_services.py
git add -p observability.tf
git diff --cached --check
git diff --cached
```

Stage only the two new alert resources from `observability.tf`. Then commit:

```bash
git commit -m "Alert on public route and TLS failures"
```

---

### Task 3: Fold public monitoring into the Jellyfin dashboard

**Files:**
- Modify: `tests/observability/test_public_services.py`
- Modify: `observability/jellyfin-dashboard.json.tftpl`

**Interfaces:**
- Consumes: Prometheus metrics labeled `job="blackbox"`, `service`, and `service_name`; existing `${datasource_uid}` template input.
- Produces: dashboard title `Public Services`, overview panel IDs 10-15, expanded row ID 16, and the unchanged Jellyfin panel IDs 1, 2, 3, 4, 8, and 9 below that row.

- [ ] **Step 1: Add failing dashboard structure tests**

Add this method to `ProbeConfigurationTest`:

```python
    def test_dashboard_combines_public_overview_and_jellyfin_details(self):
        dashboard = terraform_json(
            'jsondecode(templatefile('
            '"observability/jellyfin-dashboard.json.tftpl", '
            '{ datasource_uid = "fixture-prometheus" }))'
        )
        panels = dashboard["panels"]
        panel_by_id = {panel["id"]: panel for panel in panels}

        self.assertEqual(dashboard["uid"], "jellyfin")
        self.assertEqual(dashboard["title"], "Public Services")
        self.assertTrue({10, 11, 12, 13, 14, 15, 16} <= set(panel_by_id))
        self.assertTrue({1, 2, 3, 4, 8, 9} <= set(panel_by_id))

        public_row = panel_by_id[10]
        self.assertEqual(public_row["type"], "row")
        self.assertFalse(public_row["collapsed"])
        self.assertEqual(public_row["title"], "Public service overview")

        jellyfin_row = panel_by_id[16]
        self.assertEqual(jellyfin_row["type"], "row")
        self.assertFalse(jellyfin_row["collapsed"])
        self.assertEqual(jellyfin_row["title"], "Jellyfin details")

        self.assertEqual(panel_by_id[11]["type"], "stat")
        self.assertEqual(panel_by_id[12]["type"], "state-timeline")
        self.assertEqual(panel_by_id[13]["type"], "timeseries")
        self.assertEqual(panel_by_id[14]["title"], "Latest HTTP status")
        self.assertEqual(panel_by_id[15]["title"], "TLS validity remaining")
        self.assertTrue(all(panel_by_id[id]["gridPos"]["y"] >= 28 for id in (1, 2, 3, 4, 8, 9)))
```

- [ ] **Step 2: Run the dashboard test and verify it fails**

Run:

```bash
python3 -m unittest   tests.observability.test_public_services.ProbeConfigurationTest.test_dashboard_combines_public_overview_and_jellyfin_details   -v
```

Expected: FAIL because the dashboard title is `Jellyfin` and overview panels 10-16 do not exist.

- [ ] **Step 3: Update dashboard identity**

In `observability/jellyfin-dashboard.json.tftpl`, preserve `"uid": "jellyfin"` and change the metadata to:

```json
  "title": "Public Services",
  "tags": ["homelab", "public-services", "jellyfin", "traefik"],
```

Keep the existing 24-hour default range and one-minute refresh.

- [ ] **Step 4: Add the expanded overview row and current-status panel**

Insert these as the first two entries in `panels`:

```json
    {
      "id": 10,
      "type": "row",
      "title": "Public service overview",
      "collapsed": false,
      "panels": [],
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 0 }
    },
    {
      "id": 11,
      "type": "stat",
      "title": "Current service status",
      "description": "Latest in-network HTTPS probe result for each public route.",
      "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
      "gridPos": { "h": 4, "w": 24, "x": 0, "y": 1 },
      "fieldConfig": {
        "defaults": {
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": { "text": "Down", "color": "red" },
                "1": { "text": "Up", "color": "green" }
              }
            },
            {
              "type": "special",
              "options": {
                "match": "null",
                "result": { "text": "Unknown", "color": "gray" }
              }
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "green", "value": 1 }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "auto",
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "textMode": "value_and_name",
        "wideLayout": true
      },
      "targets": [
        {
          "refId": "A",
          "expr": "probe_success{job=\"blackbox\"}",
          "instant": true,
          "legendFormat": "{{service_name}}"
        }
      ]
    },
```

- [ ] **Step 5: Add availability and latency history panels**

Insert:

```json
    {
      "id": 12,
      "type": "state-timeline",
      "title": "Availability history",
      "description": "Probe state over the selected dashboard time range.",
      "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 5 },
      "fieldConfig": {
        "defaults": {
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": { "text": "Down", "color": "red" },
                "1": { "text": "Up", "color": "green" }
              }
            }
          ],
          "custom": { "fillOpacity": 80, "lineWidth": 0, "spanNulls": false }
        },
        "overrides": []
      },
      "options": {
        "alignValue": "left",
        "legend": { "displayMode": "list", "placement": "bottom", "showLegend": false },
        "mergeValues": true,
        "rowHeight": 0.9,
        "showValue": "auto",
        "tooltip": { "mode": "single", "sort": "none" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "probe_success{job=\"blackbox\"}",
          "legendFormat": "{{service_name}}"
        }
      ]
    },
    {
      "id": 13,
      "type": "timeseries",
      "title": "Public route response latency",
      "description": "Total time for DNS, connection, TLS, redirects, and the final HTTP response.",
      "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
      "gridPos": { "h": 9, "w": 24, "x": 0, "y": 13 },
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "min": 0,
          "custom": { "fillOpacity": 12, "lineWidth": 2, "showPoints": "never" }
        },
        "overrides": []
      },
      "options": {
        "legend": { "calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "desc" }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "probe_duration_seconds{job=\"blackbox\"}",
          "legendFormat": "{{service_name}}"
        }
      ]
    },
```

- [ ] **Step 6: Add HTTP and TLS detail panels**

Insert:

```json
    {
      "id": 14,
      "type": "stat",
      "title": "Latest HTTP status",
      "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
      "gridPos": { "h": 5, "w": 12, "x": 0, "y": 22 },
      "fieldConfig": {
        "defaults": { "color": { "mode": "fixed", "fixedColor": "blue" } },
        "overrides": []
      },
      "options": {
        "colorMode": "value",
        "graphMode": "none",
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "textMode": "value_and_name",
        "wideLayout": true
      },
      "targets": [
        {
          "refId": "A",
          "expr": "probe_http_status_code{job=\"blackbox\"}",
          "instant": true,
          "legendFormat": "{{service_name}}"
        }
      ]
    },
    {
      "id": 15,
      "type": "stat",
      "title": "TLS validity remaining",
      "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
      "gridPos": { "h": 5, "w": 12, "x": 12, "y": 22 },
      "fieldConfig": {
        "defaults": {
          "unit": "suffix: days",
          "decimals": 1,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "orange", "value": 14 },
              { "color": "green", "value": 30 }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "value",
        "graphMode": "none",
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false },
        "textMode": "value_and_name",
        "wideLayout": true
      },
      "targets": [
        {
          "refId": "A",
          "expr": "(probe_ssl_earliest_cert_expiry{job=\"blackbox\"} - time()) / 86400",
          "instant": true,
          "legendFormat": "{{service_name}}"
        }
      ]
    },
    {
      "id": 16,
      "type": "row",
      "title": "Jellyfin details",
      "collapsed": false,
      "panels": [],
      "gridPos": { "h": 1, "w": 24, "x": 0, "y": 27 }
    },
```

- [ ] **Step 7: Move the existing Jellyfin panels below the expanded row**

Keep every existing panel object and query. Change only these `gridPos.y` values:

```text
Panel 4:  0 -> 28
Panel 9:  0 -> 28
Panel 2:  4 -> 32
Panel 8:  4 -> 32
Panel 1: 10 -> 38
Panel 3: 20 -> 48
```

Expanded Grafana rows keep their child panels flattened after the row with `"panels": []`; do not nest the Jellyfin panels inside row ID 16.

- [ ] **Step 8: Run dashboard and configuration tests**

Run:

```bash
python3 -m unittest tests/observability/test_public_services.py -v
terraform console <<'EOF'
jsondecode(templatefile("observability/jellyfin-dashboard.json.tftpl", {
  datasource_uid = "fixture-prometheus"
})) != null
EOF
terraform validate
```

Expected: all unit tests pass, Terraform console prints `true`, and Terraform validation succeeds.

- [ ] **Step 9: Run the Impeccable dashboard detector once**

Run:

```bash
node /Users/reilley/.agents/skills/impeccable/scripts/detect.mjs --json   observability/jellyfin-dashboard.json.tftpl
```

Expected: no blocking dashboard-quality findings. Resolve concrete findings in one batch, rerun the unit test and dashboard render check once, and do not enter an open-ended polish loop.

- [ ] **Step 10: Commit the dashboard integration**

Run:

```bash
git add tests/observability/test_public_services.py   observability/jellyfin-dashboard.json.tftpl
git diff --cached --check
git diff --cached
```

Expected: the cached dashboard diff contains the public overview, expanded row, and only the specified position changes to existing panels. Commit:

```bash
git commit -m "Combine public service and Jellyfin monitoring"
```

---

### Task 4: Verify the integrated plan without applying it

**Files:**
- Verify: `observability.tf`
- Verify: `observability/blackbox.yml`
- Verify: `observability/prometheus.yml.tftpl`
- Verify: `observability/jellyfin-dashboard.json.tftpl`
- Verify: `tests/observability/test_public_services.py`

**Interfaces:**
- Consumes: all outputs from Tasks 1-3 and the repository's existing `.auto.tfvars` credentials.
- Produces: passing local validation and `/tmp/public-services-blackbox.tfplan` for human review; no infrastructure mutation.

- [ ] **Step 1: Run the full focused verification suite**

Run:

```bash
python3 -m unittest tests/observability/test_public_services.py -v
terraform fmt -check
terraform validate
ssh "$(terraform console <<<'var.username' | tr -d '"')@192.168.86.199"   'docker run --rm -i prom/blackbox-exporter:latest --config.file=/dev/stdin --config.check'   < observability/blackbox.yml
```

Expected: all tests pass, Terraform validates, and Blackbox Exporter reports that its config is valid.

- [ ] **Step 2: Confirm only approved feature paths changed relative to the captured baseline**

Run:

```bash
git status --short
git diff --check
git diff --cached --check
```

Compare relevant-file changes with `/tmp/public-services-preexisting.patch`. Expected feature scope is limited to:

```text
observability.tf
observability/blackbox.yml
observability/prometheus.yml (rename)
observability/prometheus.yml.tftpl
observability/jellyfin-dashboard.json.tftpl
tests/observability/fixtures/public-services.json
tests/observability/test_public_services.py
```

Do not revert, stage, or commit any pre-existing path outside this list.

- [ ] **Step 3: Produce a Terraform plan without applying**

Run:

```bash
terraform plan -out=/tmp/public-services-blackbox.tfplan
terraform show -no-color /tmp/public-services-blackbox.tfplan   > /tmp/public-services-blackbox.tfplan.txt
```

Expected plan evidence:

- one `module.blackbox_exporter` service stack is added;
- `module.prometheus` is replaced because uploaded configuration changed;
- `grafana_dashboard.jellyfin` updates in place;
- ten service rules are added across the two Grafana rule groups;
- no unrelated container replacement is caused by this feature.

Existing workspace edits may produce additional plan changes. Classify those separately instead of attributing them to this feature.

- [ ] **Step 4: Inspect feature-specific planned changes**

Run:

```bash
grep -nE 'blackbox|public_service|grafana_dashboard.jellyfin|module.prometheus'   /tmp/public-services-blackbox.tfplan.txt
```

Expected: each feature resource appears. Read the surrounding plan sections and confirm URLs use `var.domain`, alert thresholds are five minutes and 14 days, and no secret value appears in an annotation or dashboard query.

- [ ] **Step 5: Stop before deployment and report the apply checkpoint**

Report:

```text
Validation passed and the Terraform plan is ready at
/tmp/public-services-blackbox.tfplan. No terraform apply was run.
```

Include the plan summary and any unrelated changes that prevent a safe targeted review. Wait for explicit approval before applying infrastructure.
