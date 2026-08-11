# Jellyfin Separate Stat Cards and Latency Meters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace grouped latency/status summaries with independent cards and show p95/p99 latency as Faro-style horizontal 0–5 second meters.

**Architecture:** Keep the existing Prometheus queries and Terraform-managed dashboard boundary. Split the current multi-value panels into two native Grafana Bar Gauge panels and eight native Stat panels, reflow the 24-column grid, and deploy only `grafana_dashboard.jellyfin` through an inspected saved plan.

**Tech Stack:** Grafana dashboard JSON schema 39, Prometheus/PromQL, Terraform Grafana provider, `jq`, authenticated browser verification.

## Global Constraints

- Modify only `observability/jellyfin-dashboard.json.tftpl` during implementation.
- Preserve the existing user-owned `CLAUDE.md`, `.codex/`, and `AGENTS.md` changes.
- Keep all summary queries tied to `$__range` and both time-series queries tied to `$__rate_interval`.
- Do not use a fixed `[5m]` query window or a panel-level time override.
- Do not change the exporter, Prometheus, Traefik, Jellyfin, alerting, or container images.
- Do not apply a full Terraform plan or replace any container.
- The dashboard apply may update only `grafana_dashboard.jellyfin` in place.
- p95 and p99 use horizontal Basic Bar Gauges with min `0`, max `5`, and absolute green/amber/red thresholds at `0`, `1`, and `2` seconds.
- Status cards are fixed to `200`, `204`, `302`, `304`, `404`, `499`, `502`, and `Other`; every absent result renders zero.

---

### Task 1: Split the grouped summaries into independent panels

**Files:**
- Modify: `observability/jellyfin-dashboard.json.tftpl`
- Test: structural assertions executed against the rendered template

**Interfaces:**
- Consumes: existing Prometheus datasource UID template variable, Traefik router metrics, and the approved design in `docs/superpowers/specs/2026-08-09-jellyfin-stat-cards-meter-design.md`.
- Produces: a valid fourteen-panel dashboard JSON model with two latency meters, eight status cards, and no panel overlap.

- [ ] **Step 1: Verify the current template parses before editing**

Run:

```bash
set -o pipefail
sed 's/${datasource_uid}/prometheus/g' observability/jellyfin-dashboard.json.tftpl |
  jq -e '.schemaVersion == 39 and (.panels | length == 6)'
```

Expected: exit 0. Stop if the committed template is not the approved six-panel baseline.

- [ ] **Step 2: Run the intended-state structural assertion to verify RED**

Run:

```bash
set -o pipefail
sed 's/${datasource_uid}/prometheus/g' observability/jellyfin-dashboard.json.tftpl |
jq -e '
  . as $d |
  def latency($id; $title; $quantile):
    any($d.panels[];
      .id == $id and .title == $title and .type == "bargauge" and
      .fieldConfig.defaults.unit == "s" and
      .fieldConfig.defaults.min == 0 and
      .fieldConfig.defaults.max == 5 and
      .fieldConfig.defaults.thresholds == {
        "mode":"absolute",
        "steps":[
          {"color":"green","value":null},
          {"color":"orange","value":1},
          {"color":"red","value":2}
        ]
      } and
      .options.orientation == "horizontal" and
      .options.displayMode == "basic" and
      .options.showUnfilled == true and
      .options.reduceOptions.calcs == ["lastNotNull"] and
      (.targets | length == 1) and .targets[0].instant == true and
      (.targets[0].expr | contains("histogram_quantile(" + $quantile)) and
      (.targets[0].expr | contains("[$__range]"))
    );
  def status($id; $title; $selector):
    any($d.panels[];
      .id == $id and .title == $title and .type == "stat" and
      .fieldConfig.defaults.unit == "short" and
      .fieldConfig.defaults.min == 0 and
      .options.graphMode == "none" and
      .options.reduceOptions.calcs == ["lastNotNull"] and
      (.targets | length == 1) and .targets[0].instant == true and
      (.targets[0].expr | contains("[$__range]")) and
      (.targets[0].expr | contains($selector)) and
      (.targets[0].expr | endswith(" or vector(0)"))
    );
  ($d.panels | length == 14) and
  (($d.panels | map(.id) | sort) == [1,2,3,4,5,8,9,10,11,12,13,14,15,16]) and
  (($d.panels | map(.id) | unique | length) == 14) and
  (all($d.panels[].title; . != "Request latency" and . != "Status codes")) and
  latency(4; "p95 latency"; "0.95") and
  latency(9; "p99 latency"; "0.99") and
  status(5; "200"; "code=\"200\"") and
  status(10; "204"; "code=\"204\"") and
  status(11; "302"; "code=\"302\"") and
  status(12; "304"; "code=\"304\"") and
  status(13; "404"; "code=\"404\"") and
  status(14; "499"; "code=\"499\"") and
  status(15; "502"; "code=\"502\"") and
  status(16; "Other"; "code!~\"200|204|302|304|404|499|502\"") and
  (all($d.panels[] | select(.type == "timeseries") | .targets[].expr;
    contains("[$__rate_interval]"))) and
  (all($d.panels[] | select(.type != "timeseries") | .targets[].expr;
    contains("[$__range]")))
' 
```

Expected: exit non-zero because the dashboard still has grouped latency and status panels.

- [ ] **Step 3: Replace panel 4 with the p95 Bar Gauge**

Use this exact panel identity, field configuration, options, target, and layout:

```json
{
  "id": 4,
  "type": "bargauge",
  "title": "p95 latency",
  "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
  "gridPos": { "h": 8, "w": 6, "x": 12, "y": 9 },
  "fieldConfig": {
    "defaults": {
      "unit": "s",
      "min": 0,
      "max": 5,
      "color": { "mode": "thresholds" },
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "orange", "value": 1 },
          { "color": "red", "value": 2 }
        ]
      }
    },
    "overrides": []
  },
  "options": {
    "orientation": "horizontal",
    "displayMode": "basic",
    "showUnfilled": true,
    "valueMode": "color",
    "namePlacement": "auto",
    "reduceOptions": { "values": false, "calcs": ["lastNotNull"], "fields": "" }
  },
  "targets": [
    {
      "refId": "A",
      "expr": "histogram_quantile(0.95, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router=\"jellyfin@docker\"}[$__range])))",
      "instant": true
    }
  ]
}
```

- [ ] **Step 4: Add the independent p99 Bar Gauge**

Add panel `9` with the same field configuration and options as panel `4`, and these exact differing fields:

```json
{
  "id": 9,
  "type": "bargauge",
  "title": "p99 latency",
  "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
  "gridPos": { "h": 8, "w": 6, "x": 18, "y": 9 },
  "fieldConfig": {
    "defaults": {
      "unit": "s",
      "min": 0,
      "max": 5,
      "color": { "mode": "thresholds" },
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "orange", "value": 1 },
          { "color": "red", "value": 2 }
        ]
      }
    },
    "overrides": []
  },
  "options": {
    "orientation": "horizontal",
    "displayMode": "basic",
    "showUnfilled": true,
    "valueMode": "color",
    "namePlacement": "auto",
    "reduceOptions": { "values": false, "calcs": ["lastNotNull"], "fields": "" }
  },
  "targets": [
    {
      "refId": "A",
      "expr": "histogram_quantile(0.99, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router=\"jellyfin@docker\"}[$__range])))",
      "instant": true
    }
  ]
}
```

Do not introduce a second target or a panel-level time override.

- [ ] **Step 5: Replace panel 5 and add seven independent status panels**

Every status panel uses this exact shape:

```json
{
  "id": 5,
  "type": "stat",
  "title": "200",
  "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
  "gridPos": { "h": 5, "w": 3, "x": 0, "y": 17 },
  "fieldConfig": {
    "defaults": { "unit": "short", "min": 0 },
    "overrides": []
  },
  "options": {
    "reduceOptions": { "values": false, "calcs": ["lastNotNull"], "fields": "" },
    "graphMode": "none",
    "colorMode": "value",
    "textMode": "value"
  },
  "targets": [
    {
      "refId": "A",
      "expr": "sum(increase(traefik_router_requests_total{router=\"jellyfin@docker\",code=\"200\"}[$__range])) or vector(0)",
      "instant": true
    }
  ]
}
```

Create the other seven complete panels using this exact mapping; only the listed identity, grid x-position, and selector change:

| ID | Title | x | Selector inside the same query |
|---:|---|---:|---|
| 10 | `204` | 3 | `code="204"` |
| 11 | `302` | 6 | `code="302"` |
| 12 | `304` | 9 | `code="304"` |
| 13 | `404` | 12 | `code="404"` |
| 14 | `499` | 15 | `code="499"` |
| 15 | `502` | 18 | `code="502"` |
| 16 | `Other` | 21 | `code!~"200|204|302|304|404|499|502"` |

For every row, keep `y=17`, `w=3`, and `h=5`. The exact Other expression is:

```promql
sum(increase(traefik_router_requests_total{router="jellyfin@docker",code!~"200|204|302|304|404|499|502"}[$__range])) or vector(0)
```

- [ ] **Step 6: Reflow the table and request-rate graph**

Change only these `gridPos` values:

```json
"Egress by user": { "h": 8, "w": 12, "x": 0, "y": 9 }
"Request rate, public vs LAN": { "h": 8, "w": 24, "x": 0, "y": 22 }
```

Keep panels `1` and `2` unchanged. Keep every existing target in panels `1`, `2`, `3`, and `8` unchanged.

- [ ] **Step 7: Run structural and non-overlap assertions to verify GREEN**

Run the exact structural assertion from Step 2; expected exit 0.

Then run:

```bash
set -o pipefail
sed 's/${datasource_uid}/prometheus/g' observability/jellyfin-dashboard.json.tftpl |
jq -e '
  [.panels[].gridPos] as $p |
  def overlap($a; $b):
    ($a.x < ($b.x + $b.w)) and ($b.x < ($a.x + $a.w)) and
    ($a.y < ($b.y + $b.h)) and ($b.y < ($a.y + $a.h));
  all(range(0; $p|length); . as $i |
    all(range($i + 1; $p|length); . as $j |
      overlap($p[$i]; $p[$j]) | not))
'
```

Expected: `true` and exit 0.

- [ ] **Step 8: Run repository validation**

Run:

```bash
terraform fmt -check
terraform validate -no-color
git diff --check
git status --short
```

Expected: formatting and diff checks pass. Terraform validation passes with only the existing Home Assistant development-override warning. Status contains the dashboard template plus the pre-existing user-owned files.

- [ ] **Step 9: Commit Task 1**

```bash
git add observability/jellyfin-dashboard.json.tftpl
git commit -m "Split Jellyfin dashboard metric cards"
```

Expected: the commit contains only the dashboard template.

---

### Task 2: Deploy and verify only the Grafana dashboard

**Files:**
- No tracked repository changes expected

**Interfaces:**
- Consumes: the committed fourteen-panel dashboard from Task 1, the existing Grafana folder UID `afu9hvo3v3g8wa`, and the Prometheus datasource UID `prometheus`.
- Produces: an in-place update of `grafana_dashboard.jellyfin`, authenticated rendering evidence, and a dashboard-only no-change convergence plan.

- [ ] **Step 1: Capture pre-deployment state**

Run:

```bash
git status --short
terraform fmt -check
terraform validate -no-color
```

Render the dashboard and run both Task 1 GREEN assertions again. Expected: all checks pass and status contains only the pre-existing user-owned files.

- [ ] **Step 2: Temporarily cut only the dashboard's transitive dependencies**

In `observability.tf`, temporarily replace exactly:

```hcl
folder = grafana_folder.homelab.uid
```

with:

```hcl
folder = "afu9hvo3v3g8wa"
```

Temporarily replace exactly:

```hcl
config_json = templatefile("${path.module}/observability/jellyfin-dashboard.json.tftpl", {
  datasource_uid = grafana_data_source.prometheus.uid
})
```

with:

```hcl
config_json = templatefile("${path.module}/observability/jellyfin-dashboard.json.tftpl", {
  datasource_uid = "prometheus"
})
```

Do not modify any other expression.

- [ ] **Step 3: Create and inspect the dashboard-only saved plan**

Run:

```bash
terraform plan -no-color \
  -target=grafana_dashboard.jellyfin \
  -out=/tmp/jellyfin-stat-cards.tfplan
terraform show -json /tmp/jellyfin-stat-cards.tfplan |
  jq -e '[.resource_changes[] |
    select(.change.actions != ["no-op"]) |
    {address,actions:.change.actions}] == [
      {"address":"grafana_dashboard.jellyfin","actions":["update"]}
    ]'
```

Expected: the only actionful resource is an in-place dashboard update. Stop if the plan includes any create, delete, replacement, container, image, data-source, or folder action.

- [ ] **Step 4: Restore `observability.tf` before applying**

Restore the two exact committed expressions from Task 2 Step 2, then run:

```bash
terraform fmt -check
git diff --exit-code -- observability.tf
git diff --check
```

Expected: `observability.tf` has no diff. Do not apply while the temporary dependency cut remains in the worktree.

- [ ] **Step 5: Apply the reviewed saved plan**

Run:

```bash
terraform apply -no-color /tmp/jellyfin-stat-cards.tfplan
```

Expected: `0 added, 1 changed, 0 destroyed`, naming only `grafana_dashboard.jellyfin`. No container restarts.

- [ ] **Step 6: Verify authenticated Grafana rendering and range behavior**

Open:

```text
http://grafana.localdomain/d/jellyfin/jellyfin?from=now-5m&to=now
```

Verify:

- fourteen panels render;
- p95 and p99 are separate cards with visible horizontal filled meters;
- each latency meter spans 0–5 seconds and uses green below 1, amber from 1–2, and red above 2;
- `200`, `204`, `302`, `304`, `404`, `499`, `502`, and `Other` are eight separate cards;
- absent status codes show `0`, not `No data`;
- the Egress-by-user table still has only User and Egress and remains descending;
- both time-series panels still render.

Change the URL to `from=now-1h&to=now`. Confirm the displayed latency and status totals refresh for the one-hour range. Capture screenshots of the latency/status row at both ranges.

- [ ] **Step 7: Generate an isolated convergence plan**

Repeat the two-literal dependency cut from Step 2, then run:

```bash
terraform plan -no-color \
  -target=grafana_dashboard.jellyfin \
  -detailed-exitcode \
  -out=/tmp/jellyfin-stat-cards-converged.tfplan
terraform show -json /tmp/jellyfin-stat-cards-converged.tfplan |
  jq -e '[.resource_changes[] |
    select(.change.actions != ["no-op"])] == []'
```

Expected: Terraform plan exits 0 with `No changes`, and the actionful-resource assertion returns `true`.

Restore the two committed expressions again and require:

```bash
git diff --exit-code -- observability.tf
```

- [ ] **Step 8: Run final verification**

Run:

```bash
set -o pipefail
sed 's/${datasource_uid}/prometheus/g' observability/jellyfin-dashboard.json.tftpl | jq -e .
terraform fmt -check
terraform validate -no-color
git diff --check
git status --short
```

Run the complete Task 1 structural and non-overlap assertions once more. Expected: every check passes and status contains only the user-owned `CLAUDE.md`, `.codex/`, and `AGENTS.md` changes.

Do not run or apply a full Terraform plan. Do not restart any service.

---

## Completion Criteria

1. The dashboard contains exactly fourteen non-overlapping panels with unique IDs.
2. p95 and p99 render in separate native horizontal Bar Gauge cards.
3. Both latency meters use a 0–5 second scale and thresholds at 1 and 2 seconds.
4. The seven named HTTP codes and Other render in eight independent Stat cards.
5. Missing status series render zero and Other captures every unnamed code.
6. Every summary follows `$__range`; both time-series graphs follow `$__rate_interval`.
7. The existing traffic graph, public-egress card, user table, and request-rate graph remain functional.
8. The only applied Terraform change is the in-place `grafana_dashboard.jellyfin` update.
9. Structural JSON assertions, overlap checks, Terraform formatting/validation, authenticated rendering, range switching, and isolated convergence all pass.
