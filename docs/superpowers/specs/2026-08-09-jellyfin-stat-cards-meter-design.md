# Jellyfin Separate Stat Cards and Latency Meters Design

## Goal

Make the Jellyfin dashboard's latency and HTTP-status summaries easier to scan by replacing grouped multi-value cards with independent cards. Present p95 and p99 latency using Faro-style horizontal meters while keeping every summary tied to the selected Grafana dashboard range.

## Scope

This change is limited to the Terraform-managed Jellyfin Grafana dashboard template at `observability/jellyfin-dashboard.json.tftpl` and its safe dashboard-only deployment. It does not change the exporter, Prometheus configuration, Traefik, Jellyfin, or any container image.

## Visualization Choice

Use Grafana's native `bargauge` visualization for p95 and p99. A normal Stat panel supports an optional sparkline but not a true horizontal meter. The horizontal Bar Gauge is the closest native equivalent to the latency cards used by Grafana Faro dashboards and remains straightforward to provision as dashboard JSON.

Each latency percentile receives its own panel:

- `p95 latency`
- `p99 latency`

Both panels use:

- horizontal orientation;
- Basic display mode with the unfilled region visible;
- a large visible value and a horizontal filled meter;
- unit `s`;
- fixed minimum `0` and maximum `5` seconds;
- absolute thresholds: green from `0`, amber from `1`, and red from `2` seconds;
- one instant Prometheus query calculated over `$__range`;
- `lastNotNull` reduction.

The p95 and p99 PromQL calculations remain the existing `histogram_quantile` expressions. Splitting the current grouped panel must not change their semantics.

## Independent Status Cards

Replace the grouped `Status codes` panel with eight independent Stat panels:

- `200`
- `204`
- `302`
- `304`
- `404`
- `499`
- `502`
- `Other`

Each named-code panel filters the public Jellyfin router counter to exactly that code and calculates the range total with `increase(...[$__range])`. The `Other` panel excludes all seven named codes and totals every remaining status code. Every query uses an `or vector(0)` fallback so a code with no samples renders `0` instead of `No data`.

Status panels use `stat`, unit `short`, minimum zero, `lastNotNull`, no sparkline, and one value per card. Their titles provide the status-code label, so no multi-series grouping or dynamic panel creation is required.

## Layout

Use Grafana's 24-column grid:

| Panel | Position |
|---|---|
| Public response accounting rate | unchanged: `x=0,y=0,w=16,h=9` |
| Public egress | unchanged: `x=16,y=0,w=8,h=9` |
| Egress by user | `x=0,y=9,w=12,h=8` |
| p95 latency | `x=12,y=9,w=6,h=8` |
| p99 latency | `x=18,y=9,w=6,h=8` |
| Eight status cards | one row at `y=17`, each `w=3,h=5`, with `x=0,3,6,9,12,15,18,21` |
| Request rate, public vs LAN | `x=0,y=22,w=24,h=8` |

This keeps the latency meters large enough to read and makes the status cards compact without grouping them inside one panel.

## Stable Identity

Retain existing IDs where their meaning remains clear:

- panel `4` becomes `p95 latency`;
- panel `5` becomes status `200`;
- panel `3` remains the request-rate graph;
- panels `1`, `2`, and `8` retain their current identities.

Use panel `9` for p99. Use `5` for status 200, then `10` through `16` for 204, 302, 304, 404, 499, 502, and Other respectively. The final dashboard therefore has fourteen panels: the existing aggregate graph, public-egress stat, user table, two latency meters, eight status cards, and the request-rate graph.

## Time-Range Behavior

All summary queries continue to follow the dashboard time picker:

- latency meters use `$__range`;
- status cards use `$__range`;
- public egress and egress-by-user retain `$__range`;
- the two time-series graphs retain `$__rate_interval`.

No fixed `[5m]` window or panel-level time override is introduced.

## Validation and Deployment

Before deployment, render the template with a substituted test Prometheus datasource UID and assert:

- valid JSON;
- exactly fourteen panels with unique IDs;
- no grouped `Request latency` or `Status codes` panel remains;
- p95 and p99 are separate `bargauge` panels;
- both latency panels have horizontal Basic meters, a 0–5 second scale, the agreed thresholds, and `$__range` queries;
- all eight status panels are separate `stat` panels with the correct named-code or `Other` filter, `$__range`, and zero fallback;
- the grid has no overlaps;
- existing aggregate/user queries retain their range variables.

Run `terraform fmt -check`, `terraform validate -no-color`, and `git diff --check`. Generate a dashboard-isolated Terraform plan and require the only actionful resource to be `grafana_dashboard.jellyfin` updated in place. Do not apply a full plan or replace any container.

After the dashboard-only apply, verify through authenticated Grafana rendering that:

- p95 and p99 appear as separate horizontal meters;
- each status code and `Other` appears in a separate card;
- absent codes render zero;
- changing the dashboard range changes latency and status totals;
- the table and both time-series panels remain intact.

## Out of Scope

- Exact reproduction of Grafana Cloud Frontend Observability's proprietary application chrome or custom components.
- Dynamic creation of new Terraform-managed panels for arbitrary status codes.
- Changes to egress attribution, exporter metrics, traffic accounting, or alerting.
