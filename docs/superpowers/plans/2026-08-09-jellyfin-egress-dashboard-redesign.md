# Jellyfin Egress Dashboard Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce avoidable unknown Jellyfin attribution with a restart-safe 30-second delay and replace the noisy per-user graphs with a compact, time-picker-scoped dashboard.

**Architecture:** Use the access log itself as the durable pending queue: an unmapped recent public record is not checkpointed until a Jellyfin session poll supplies a mapping or its 30-second deadline expires. Publish a clean v2 counter so replay-contaminated v1 history is no longer queried. Rebuild the dashboard around one user-total table, compact latency/status stat cells, and two adaptive-rate aggregate graphs.

**Tech Stack:** Python 3.13 standard library, `unittest`, Traefik JSON access logs, Prometheus/PromQL, Grafana dashboard JSON templates, Terraform Docker/Grafana providers.

## Global Constraints

- Work directly on `main`; the operator explicitly requested no feature branch or worktree.
- Preserve the user-owned `CLAUDE.md`, `.codex/`, and `AGENTS.md` changes; never stage or modify them.
- Use only the Python standard library in exporter code.
- Attribute only exact router `jellyfin@docker`; never count `jellyfinlocal@docker`.
- Use logger field `time`, not `StartUTC`, for the 30-second deadline.
- Delay unmapped records for exactly 30 seconds; reject logger timestamps more than five seconds in the future and clamp smaller future skew to age zero.
- Keep `unknown` visible after the delay expires.
- Publish and query `jellyfin_user_egress_bytes_v2_total`; do not delete old Prometheus data.
- Every instant dashboard summary uses `$__range`; every time series uses `$__rate_interval`.
- Do not replace Traefik, Jellyfin, Prometheus, or Grafana containers.
- Accept Traefik formatter metadata `level`, `msg`, and `time`; continue excluding credentials, headers, cookies, and query strings.

---

### Task 1: Add restart-safe delayed attribution and the v2 metric

**Files:**
- Modify: `observability/jellyfin_egress_exporter.py`
- Test: `observability/test_jellyfin_egress_exporter.py`

**Interfaces:**
- Consumes: Traefik public access records containing `RouterName`, `ClientHost`, `DownstreamContentSize`, and logger `time`; `MappingCache.lookup(client_ip: str, now: float) -> str`; anchored `Checkpoint` behavior.
- Produces: `AccessEvent(client_ip: str, byte_count: int, recorded_at: float)`; constants `ATTRIBUTION_DELAY_SECONDS = 30` and `MAX_FUTURE_SKEW_SECONDS = 5`; `jellyfin_user_egress_bytes_v2_total{user,client_ip}`.

- [ ] **Step 1: Extend the access-line test fixture with logger time and write timestamp RED tests**

Update `ParseAccessLineTests.make_line` so its default entry includes:

```python
"time": "2026-08-09T20:14:40+10:00",
```

Add tests equivalent to:

```python
def test_returns_logger_time_as_epoch_seconds(self):
    event = parse_access_line(self.make_line())
    self.assertEqual(event.recorded_at, 1786270480.0)

def test_rejects_missing_naive_or_malformed_logger_time(self):
    for value in (None, "2026-08-09T20:14:40", "not-a-time"):
        overrides = {} if value is None else {"time": value}
        line = self.make_line(**overrides)
        if value is None:
            line = self.make_line()
            entry = json.loads(line)
            del entry["time"]
            line = json.dumps(entry)
        with self.subTest(value=value), self.assertRaises(ValueError):
            parse_access_line(line)
```

Keep router filtering before timestamp validation so non-public records still return `None` without requiring `time`.

- [ ] **Step 2: Run timestamp tests to verify RED**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter.ParseAccessLineTests
```

Expected: FAIL because `AccessEvent` has no `recorded_at` and `parse_access_line` does not validate `time`.

- [ ] **Step 3: Parse timezone-aware RFC 3339 logger timestamps**

Add:

```python
from datetime import datetime

ATTRIBUTION_DELAY_SECONDS = 30
MAX_FUTURE_SKEW_SECONDS = 5


def parse_recorded_at(value: object) -> float:
    if not isinstance(value, str):
        raise ValueError("time must be a timezone-aware RFC 3339 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("time must be a timezone-aware RFC 3339 timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("time must be a timezone-aware RFC 3339 timestamp")
    return parsed.timestamp()
```

Extend `AccessEvent` with `recorded_at: float` and construct it with
`parse_recorded_at(entry.get("time"))` after exact-router, byte-count, and client-IP validation.

- [ ] **Step 4: Run timestamp tests to verify GREEN**

Run the command from Step 2.

Expected: all `ParseAccessLineTests` pass.

- [ ] **Step 5: Write delayed-attribution RED tests**

Add focused tailer tests using a public line with `time = "1970-01-01T00:16:40Z"`
(epoch 1000) and an anchored checkpoint at offset zero. Cover these cases:

```python
def test_recent_unmapped_record_is_not_processed_or_checkpointed(self):
    # process at now=1029: returns 0, counter absent, checkpoint offset remains 0

def test_delayed_record_is_attributed_when_mapping_arrives(self):
    # first pass at 1001 defers; observe alice mapping; second pass at 1002
    # returns 1 and emits alice bytes exactly once

def test_unmapped_record_becomes_unknown_at_deadline(self):
    # pass at now=1030 processes once as unknown and advances checkpoint

def test_future_timestamp_is_counted_and_checkpointed(self):
    # timestamp 1006 at now=1000 is invalid: access_log_errors=1 and offset advances

def test_small_future_skew_is_deferred_from_age_zero(self):
    # timestamp 1005 at now=1000 defers without an error or checkpoint advance

def test_delayed_record_survives_reentry_and_blocks_following_lines(self):
    # two records: first unmapped/recent, second mapped; first pass processes neither;
    # after deadline both process once in original order
```

Use `checkpoint_anchor` to create anchored test checkpoints rather than legacy `anchor=None`,
so the tests isolate delay behavior from migration behavior.

- [ ] **Step 6: Run delayed-attribution tests to verify RED**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter.TailerTests
```

Expected: new tests fail because unmapped records are processed immediately.

- [ ] **Step 7: Implement checkpoint-backed deferral**

In the binary tail loop, capture `line_start = handle.tell()` before `readline()`. After
parsing a public event:

```python
age = now - event.recorded_at
if age < -MAX_FUTURE_SKEW_SECONDS:
    raise ValueError("time is too far in the future")
age = max(0.0, age)
username = cache.lookup(event.client_ip, now)
if username == "unknown" and age < ATTRIBUTION_DELAY_SECONDS:
    handle.seek(line_start)
    break
state.apply(event, username)
processed += 1
```

Do not save a checkpoint on the deferred branch. Retain existing behavior for malformed
records: increment `access_log_errors`, then checkpoint the line and continue. Retain the
partial-line rule and SHA-256 anchor generation exactly.

- [ ] **Step 8: Run delayed-attribution tests to verify GREEN**

Run the command from Step 6.

Expected: all `TailerTests` pass, including copy-truncate and partial-line regressions.

- [ ] **Step 9: Write and run the v2 metric RED test**

Add:

```python
def test_renders_only_v2_attribution_metric_name(self):
    state = MetricState()
    state.apply(AccessEvent("203.0.113.8", 25, 1000.0), "alice")
    rendered = state.render(active_mappings=1)
    self.assertIn("jellyfin_user_egress_bytes_v2_total", rendered)
    self.assertNotIn("jellyfin_user_egress_bytes_total{", rendered)
```

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter.MetricStateTests.test_renders_only_v2_attribution_metric_name
```

Expected: FAIL because output still uses the v1 metric.

- [ ] **Step 10: Rename the emitted metric and verify the complete exporter suite**

Change only the public metric name and HELP/TYPE line references to
`jellyfin_user_egress_bytes_v2_total`. Update existing unit assertions and constructors for
the new `AccessEvent` field.

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter \
  observability.test_traefik_access_log_rotator
python3 -m py_compile \
  observability/jellyfin_egress_exporter.py \
  observability/traefik_access_log_rotator.py
```

Expected: all tests pass and both modules compile.

- [ ] **Step 11: Commit Task 1**

```bash
git add observability/jellyfin_egress_exporter.py observability/test_jellyfin_egress_exporter.py
git commit -m "Delay unmapped Jellyfin egress attribution"
```

---

### Task 2: Replace per-user graphs with the compact range-scoped dashboard

**Files:**
- Modify: `observability/jellyfin-dashboard.json.tftpl`

**Interfaces:**
- Consumes: `jellyfin_user_egress_bytes_v2_total{user,client_ip}` from Task 1 and existing Traefik router counters/histograms.
- Produces: six Grafana panels; a `User | Egress` descending table; range-scoped latency/status stat cells; adaptive aggregate rate graphs.

- [ ] **Step 1: Record the pre-edit JSON gate and write a failing structural assertion**

Run the existing parse gate:

```bash
sed 's/${datasource_uid}/prometheus/g' observability/jellyfin-dashboard.json.tftpl | jq -e . >/dev/null
```

Expected: exit 0.

Then run this intended-state assertion before editing:

```bash
set -o pipefail
sed 's/${datasource_uid}/prometheus/g' observability/jellyfin-dashboard.json.tftpl |
  jq -e '
    (.panels | length == 6) and
    (any(.panels[]; .title == "Egress by user" and .type == "table")) and
    (any(.panels[]; .title == "Request latency" and .type == "stat")) and
    (any(.panels[]; .title == "Status codes" and .type == "stat")) and
    (all(.panels[].title; . != "Public egress by user" and . != "Upload rate by user"))
  '
```

Expected: exit non-zero because the template still has eight panels and old types/titles.

- [ ] **Step 2: Reflow the six panels**

Keep IDs stable and use this layout:

| Panel | ID | Grid position |
|---|---:|---|
| Public response accounting rate | 1 | `h=9,w=16,x=0,y=0` |
| Public egress | 2 | `h=9,w=8,x=16,y=0` |
| Egress by user | 8 | `h=8,w=10,x=0,y=9` |
| Request latency | 4 | `h=8,w=6,x=10,y=9` |
| Status codes | 5 | `h=8,w=8,x=16,y=9` |
| Request rate, public vs LAN | 3 | `h=8,w=24,x=0,y=17` |

Remove panel IDs 6 and 7 completely.

- [ ] **Step 3: Update the two remaining time-series panels**

Panel 1:

- Rename to `Public response accounting rate`.
- Replace `[5m]` with `[$__rate_interval]`.
- Add description:
  `Completed public-router response bytes accounted over time; not physical WAN-interface throughput and may include public-hostname hairpin traffic.`

Panel 3: replace `[5m]` with `[$__rate_interval]`; retain both public and LAN router series.

- [ ] **Step 4: Rebuild panel 8 as the user-only descending table**

Use one instant table target:

```json
{
  "refId": "A",
  "expr": "sort_desc(sum by (user) (increase(jellyfin_user_egress_bytes_v2_total[$__range])))",
  "instant": true,
  "format": "table"
}
```

Use `labelsToFields`, then `organize` with `Time` excluded, `user` and `Value` ordered,
`user` renamed to `User`, and `Value` renamed to `Egress`. Add table options:

```json
"options": {
  "sortBy": [{"displayName": "Egress", "desc": true}]
}
```

Keep a field override that assigns `decbytes` to `Egress`. Do not include or filter
`client_ip`; grouping only by `user` removes it at the query boundary.

- [ ] **Step 5: Convert request latency to p95/p99 stat cells**

Rename panel 4 to `Request latency`, set type `stat`, and use two instant targets:

```promql
histogram_quantile(0.95, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router="jellyfin@docker"}[$__range])))
```

```promql
histogram_quantile(0.99, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router="jellyfin@docker"}[$__range])))
```

Use legend formats `p95` and `p99`, unit `s`, minimum zero, no graph sparkline, and
`lastNotNull` reduction so the two returned fields render as separate compact stat cells.

- [ ] **Step 6: Convert status codes to range-total stat cells**

Rename panel 5 to `Status codes`, set type `stat`, and use this instant target:

```json
{
  "refId": "A",
  "expr": "sum by (code) (increase(traefik_router_requests_total{router=\"jellyfin@docker\"}[$__range]))",
  "legendFormat": "{{code}}",
  "instant": true
}
```

Use unit `short`, minimum zero, no graph sparkline, and `lastNotNull` reduction. Grafana
will render one stat cell for every returned `code` series.

- [ ] **Step 7: Run exact dashboard assertions**

Run:

```bash
set -o pipefail
sed 's/${datasource_uid}/prometheus/g' observability/jellyfin-dashboard.json.tftpl |
  jq -e '
    (.panels | length == 6) and
    ([.panels[].id] | sort == [1,2,3,4,5,8]) and
    (all(.panels[].title; . != "Public egress by user" and . != "Upload rate by user")) and
    (any(.panels[]; .id == 8 and .type == "table" and
      (.targets[0].expr | contains("sum by (user)") and contains("jellyfin_user_egress_bytes_v2_total")) and
      (.targets[0].expr | contains("client_ip") | not) and
      .options.sortBy[0] == {"displayName":"Egress","desc":true})) and
    (any(.panels[]; .id == 4 and .type == "stat" and
      ([.targets[].legendFormat] | sort == ["p95","p99"]) and
      all(.targets[].expr; contains("[$__range]")))) and
    (any(.panels[]; .id == 5 and .type == "stat" and
      (.targets[0].expr | contains("[$__range]")))) and
    (all(.panels[] | select(.type == "timeseries") | .targets[].expr; contains("[$__rate_interval]")))
  '
rg -n 'jellyfin_user_egress_bytes_total|\[5m\]|client_ip|Public egress by user|Upload rate by user' \
  observability/jellyfin-dashboard.json.tftpl
terraform fmt -check
terraform validate -no-color
```

Expected: `jq`, formatting, and Terraform validation pass. `rg` exits 1 because none of
the obsolete metric/name/fixed-window/client-IP strings remain. The only accepted
validation warning is the existing Home Assistant provider development override.

- [ ] **Step 8: Commit Task 2**

```bash
git add observability/jellyfin-dashboard.json.tftpl
git commit -m "Simplify Jellyfin egress dashboard"
```

---

### Task 3: Deploy only the exporter and dashboard, then run live gates

**Files:**
- No tracked repository changes expected.

**Interfaces:**
- Consumes: Task 1 exporter script, Task 2 dashboard template, configured `jellyfin_api_key`, live Jellyfin Known Proxy setting, active Prometheus/Grafana services.
- Produces: deployed v2 attribution, a six-panel Grafana dashboard, and evidence that the delay avoids cold-start unknown labels without service collateral.

- [ ] **Step 1: Capture pre-deployment state and health**

Record:

```bash
git status --short
curl -fsS http://prometheus.localdomain/api/v1/targets |
  jq -c '.data.activeTargets[] | select(.scrapeUrl == "http://jellyfin-egress-exporter:9101/metrics") | {health,lastError,lastScrape}'
docker --host ssh://reilley@192.168.86.199 exec jellyfin-egress-exporter \
  python -c 'import json; p=json.load(open("/state/checkpoint.json")); print({"inode":p.get("inode"),"offset":p.get("offset"),"anchor_length":len(p.get("anchor") or "")})'
```

Expected: exporter target is `up`, checkpoint anchor length is 64, and status contains only
the pre-existing user files plus committed task changes.

- [ ] **Step 2: Generate and inspect the exporter-only plan**

```bash
terraform plan -no-color \
  -target=module.jellyfin_egress_exporter \
  -out=/tmp/jellyfin-egress-delay.tfplan
terraform show -json /tmp/jellyfin-egress-delay.tfplan |
  jq -e '[.resource_changes[] | {address,actions:.change.actions}] == [{"address":"module.jellyfin_egress_exporter.docker_container.container","actions":["delete","create"]}]'
```

Expected: exactly one exporter container replacement. Stop if any other resource appears.

- [ ] **Step 3: Create a dashboard-only saved plan without transitive image drift**

The dashboard's managed folder/data-source references transitively include the Grafana
container. To isolate the existing resource without changing committed semantics, temporarily
replace only these two expressions in `observability.tf`:

```hcl
folder = "afu9hvo3v3g8wa"

config_json = templatefile("${path.module}/observability/jellyfin-dashboard.json.tftpl", {
  datasource_uid = "prometheus"
})
```

Generate:

```bash
terraform plan -no-color \
  -target=grafana_dashboard.jellyfin \
  -out=/tmp/jellyfin-dashboard-redesign.tfplan
terraform show -json /tmp/jellyfin-dashboard-redesign.tfplan |
  jq -e '[.resource_changes[] | {address,actions:.change.actions}] == [{"address":"grafana_dashboard.jellyfin","actions":["update"]}]'
```

Immediately restore the committed expressions:

```hcl
folder = grafana_folder.homelab.uid

config_json = templatefile("${path.module}/observability/jellyfin-dashboard.json.tftpl", {
  datasource_uid = grafana_data_source.prometheus.uid
})
```

Run `git diff -- observability.tf` and require empty output before applying either saved
plan. Stop if the dashboard plan contains a container replacement or if restoration leaves
a diff.

- [ ] **Step 4: Apply the two reviewed saved plans**

```bash
terraform apply -no-color /tmp/jellyfin-egress-delay.tfplan
terraform apply -no-color /tmp/jellyfin-dashboard-redesign.tfplan
```

Expected: exporter apply reports `1 added, 0 changed, 1 destroyed`; dashboard apply reports
`0 added, 1 changed, 0 destroyed`. No other container restarts.

- [ ] **Step 5: Verify v2 scrape health and cold-start delay behavior**

Wait for at least three 15-second session polls/scrapes while an external Jellyfin stream
is active. Then query:

```promql
sum by (user) (increase(jellyfin_user_egress_bytes_v2_total[5m]))
```

```promql
sum(increase(jellyfin_egress_unattributed_bytes_total[5m]))
```

Confirm a positive active username series when payload bytes complete. Compare the
checkpoint offset before and after; it must advance, retain a 64-character anchor, and not
increment `jellyfin_egress_checkpoint_discontinuities_total` beyond its pre-deployment
baseline. Confirm access-log and Jellyfin API failure counters remain zero.

If active clients complete only zero-byte/cached responses, document that evidence and
keep playback running until a positive response completes; do not manufacture a pass.

- [ ] **Step 6: Verify the authenticated Grafana rendering**

Open the Jellyfin dashboard with a range that includes new v2 bytes and verify:

- exactly six panels render;
- no per-user bar or rate graph exists;
- the user table has only `User` and `Egress` and is descending;
- p95 and p99 appear as separate stat cells;
- each observed status code appears as a separate stat cell;
- changing the time range changes table totals, latency quantiles, and status counts;
- the accounting-rate description states it is not physical WAN throughput.

- [ ] **Step 7: Run final verification and convergence checks**

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=observability python3 -m unittest -v \
  observability.test_jellyfin_egress_exporter \
  observability.test_traefik_access_log_rotator
python3 -m py_compile \
  observability/jellyfin_egress_exporter.py \
  observability/traefik_access_log_rotator.py
terraform fmt -check
terraform validate -no-color
git diff --check
git status --short
```

Generate isolated no-change plans for the exporter and dashboard using the same target and
temporary dependency-cut procedure. Expected: both report `No changes`. A full plan may
still report the previously documented unrelated image digest drift; record it separately
and do not apply it.

Expected worktree status contains only the user-owned `CLAUDE.md`, `.codex/`, and
`AGENTS.md`. Remove generated `observability/__pycache__/` before completion.

---

## Completion Criteria

1. Unmapped public records remain uncheckpointed for up to 30 seconds and survive restart/re-entry.
2. A mapping arriving during the delay attributes the record to the latest username.
3. Deadline expiry records honest `unknown`; malformed/future timestamps never wedge the tailer.
4. The v2 metric is cleanly scraped and the v1 attribution metric is absent from dashboard queries.
5. The dashboard has exactly six panels and all summaries/rates use the time-picker variables specified above.
6. The user table contains only `User` and `Egress`, sorted descending.
7. Status codes and p95/p99 latency render as compact stat cells.
8. No service other than the exporter restarts; the Grafana dashboard updates in place.
9. Full tests, compilation, JSON assertions, Terraform formatting/validation, live health, and isolated convergence checks pass.
