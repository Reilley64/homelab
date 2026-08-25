# Public Services Blackbox Monitoring Design

## Summary

Add in-network synthetic monitoring for every public homelab service with Prometheus Blackbox Exporter. Prometheus will probe each public HTTPS route, Grafana will show a shared availability overview, and Grafana-managed alerts will notify Discord when a route stays unavailable or its TLS certificate nears expiry.

The existing Jellyfin dashboard will become the combined **Public Services** dashboard. The new public-service overview will appear first. All existing Jellyfin panels will remain in an expanded, collapsible **Jellyfin details** row beneath it.

## Goals

- Probe all five public routes: Jellyfin, Seerr, Immich, Bitwarden, and Foundry.
- Exercise public DNS, HTTPS, Traefik public routing, and the application response from inside the homelab.
- Display current availability, availability history, response latency, HTTP status, and TLS certificate expiry.
- Notify the existing Discord contact point after a service remains unavailable for five minutes.
- Warn through Discord when a certificate has fewer than 14 days remaining.
- Keep all monitoring configuration in Terraform and repository-managed uploaded files.
- Preserve every existing Jellyfin dashboard panel and query.

## Non-goals

- Verifying reachability from an independent external network.
- Adding Grafana Cloud or Grafana Synthetic Monitoring.
- Authenticating to applications or testing signed-in user workflows.
- Probing private containers or local-only routes.
- Changing the existing Jellyfin metrics collection or alert delivery channel.

## Architecture

### Service inventory

Terraform will define one shared public-service check inventory containing a stable service key, display name, and public HTTPS URL for:

- `jellyfin`
- `seerr`
- `immich`
- `bitwarden`
- `foundry`

The inventory will derive URLs from `var.domain`. It will be reused when rendering Prometheus targets and when creating service-specific alert rules, so target and alert labels cannot drift apart.

### Blackbox Exporter

A `prom/blackbox-exporter` container will be created through `modules/service`, consistent with the repository's service pattern. It will attach to `docker_network.observability` and will not receive a Traefik route or published host port.

A repository-managed Blackbox Exporter configuration will be uploaded into the container. Its HTTPS module will:

- use the HTTP prober;
- allow redirects;
- require the final response to have a `2xx` status;
- require TLS for the public URL;
- use IPv4 for predictable compatibility with the homelab's public routing;
- time out after 10 seconds.

No application credentials, API keys, or private health endpoints will be used.

### Prometheus probe flow

The Prometheus configuration will become a Terraform template so it can receive `var.domain` and the shared service inventory without hard-coded production hostnames.

Prometheus will scrape `/probe` on Blackbox Exporter once every 60 seconds for each public HTTPS target. Multi-target relabeling will pass the public URL as the probe target while retaining a stable `service` label and readable service name. Prometheus will also scrape Blackbox Exporter's own `/metrics` endpoint so exporter health is visible.

The data flow is:

```text
Prometheus -> Blackbox Exporter -> public DNS/HTTPS route -> Traefik -> container
           -> Prometheus metrics -> Grafana dashboard and alert rules
```

Because the exporter runs inside the homelab, the probe may use router hairpin NAT. It validates the route as observed from the homelab, not from an external user's network.

### Probe outcomes

The primary result is `probe_success`:

- `1`: DNS, connection, TLS, redirects, and final HTTP validation succeeded.
- `0`: any required stage failed or the probe timed out.

Supporting metrics provide total duration, HTTP status, phase timings, and earliest TLS certificate expiry. A successful redirect chain is accepted only when its final response is `2xx`.

## Dashboard Design

The existing Terraform-managed dashboard will keep its stable UID to avoid breaking links, but its title and tags will change from Jellyfin-specific naming to **Public Services**.

### Public service overview

The first expanded section will show all five services and use the stable `service` label consistently. It will contain:

1. **Current service status** — clear up/down values for all five services, with success and failure colors.
2. **Availability timeline** — each service's probe state over the selected dashboard time range.
3. **Response latency** — total probe duration over time, separated by service.
4. **HTTP and TLS details** — latest HTTP status and remaining certificate lifetime for every service.

Empty or missing probe data must display as unknown/no data rather than healthy. Labels and legends will use readable service names rather than raw URLs.

### Jellyfin details

A Grafana row named **Jellyfin details** will follow the public-service overview. It will be collapsible but expanded by default.

Every existing Jellyfin panel, query, description, threshold, and visual treatment will remain within this section. Panel IDs will remain stable where practical. Grid positions will be adjusted only as required to place the panels below the row and preserve the current layout.

A service dropdown will not be added. The public overview already compares all services, while the existing Jellyfin panels have no meaningful equivalents for the other applications.

## Alerting

Alerts will use the existing Prometheus data source, Homelab folder, and Discord contact point.

### Availability

Each service will have an independently identified alert instance. An alert will enter pending state when its current probe is unsuccessful and fire only after the condition remains true for five minutes. Missing probe data for a service will be treated as a monitoring failure rather than as healthy.

Alert annotations will include the service display name, public URL, and a concise explanation. Recovery will use Grafana's normal resolved notification through the existing Discord contact point.

### TLS expiry

Each service will have a warning condition when its earliest observed certificate expiry is less than 14 days away. The warning will remain service-specific and will identify the affected URL. Availability alerts cover missing probe telemetry, so missing certificate data will not independently create a misleading expiry alert.

### Evaluation errors

Alert evaluation errors will use Grafana's alerting state so a broken query or data-source error does not silently hide failures.

## Files and Responsibilities

Expected implementation scope:

- `observability.tf`
  - shared public-service inventory;
  - Blackbox Exporter service;
  - rendered Prometheus configuration inputs;
  - availability and TLS alert rules;
  - updated dashboard metadata if needed.
- `observability/blackbox.yml`
  - repository-managed HTTP probe module.
- `observability/prometheus.yml.tftpl`
  - existing Prometheus scrape jobs plus rendered Blackbox targets.
- `observability/prometheus.yml`
  - replaced by the template above; no host-only generated file will be committed.
- `observability/jellyfin-dashboard.json.tftpl`
  - renamed dashboard content, public overview, and expanded Jellyfin row.

No raw Docker resources will be introduced. No credentials will be added.

## Verification

Before applying infrastructure changes:

1. Run `terraform fmt -check` and `terraform validate`.
2. Validate the Blackbox Exporter configuration with the exporter image or its supported configuration check.
3. Render and parse the Prometheus YAML template to confirm all five labeled targets and all existing scrape jobs are present.
4. Render and parse the dashboard JSON template.
5. Inspect `terraform plan` and confirm that the change adds the exporter, updates Prometheus and Grafana resources, and does not replace unrelated containers.

After explicit approval to apply:

1. Confirm Blackbox Exporter and Prometheus are healthy.
2. Confirm one `probe_success` series exists for each of the five service labels.
3. Confirm the dashboard overview has data and the **Jellyfin details** row starts expanded.
4. Confirm all availability and TLS alert rules exist and route to Discord.
5. Exercise one bounded failure or query-level test without disrupting unrelated public services, then confirm pending/firing and recovery behavior where practical.

## Success Criteria

The work is complete when all five public routes are probed every 60 seconds, their status and latency are visible in the combined dashboard, existing Jellyfin panels remain available under an expanded collapsible row, and service-specific Discord alerts cover sustained failures and certificates with fewer than 14 days remaining.
