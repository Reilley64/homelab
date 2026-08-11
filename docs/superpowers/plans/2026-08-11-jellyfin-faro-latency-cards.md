# Jellyfin Faro-Style Latency Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the p95 and p99 Bar Gauges with compact Faro-style cards whose value and unit sit above a thin horizontal meter with a moving pointer, labelled thresholds, and a quality indicator.

**Architecture:** Preinstall the signed Grafana Labs Business Text panel at an exact version, then render each latency result with a sanitized static HTML template, panel-local CSS, and a small after-render function that derives display text, quality, colour, and pointer position. Keep the existing PromQL and dashboard-range variables unchanged, test the Terraform and dashboard structure before editing, and deploy the reviewed Grafana replacement before the dashboard update.

**Tech Stack:** Terraform, Docker, Grafana 13.1.3, Business Text 6.3.0 (`marcusolsson-dynamictext-panel`), Grafana dashboard JSON schema 39, Prometheus/PromQL, Python `unittest`, `jq`, authenticated browser verification.

## Global Constraints

- Use only signed Business Text `6.3.0` from Grafana's official catalog; its catalog SHA-256 is `9e86d31dcfc6b9c7f0c8318cb313e90e29bdb71cdfca08b55058dde9747e9cb7` and its declared Grafana dependency is `>=12.3.0`.
- Keep Grafana's HTML sanitization enabled; never add `GF_PANELS_DISABLE_SANITIZE_HTML`, an unsigned-plugin allowlist, or an external script/style URL.
- Do not downgrade or pin Grafana as part of this change; the live instance currently reports Grafana `13.1.3`.
- Preserve the exact existing p95/p99 PromQL and `$__range`; do not add a fixed lookback or panel time override.
- Keep the meter scale at `0` to `5` seconds and quality thresholds at `1` and `2` seconds.
- Render `No data` for a missing/non-numeric result; never coerce it to zero or `Good`.
- Preserve all non-latency panels and their queries. Summary panels continue to use `$__range`; time-series panels continue to use `$__rate_interval`.
- Expected tracked implementation changes are limited to `observability.tf`, `observability/jellyfin-dashboard.json.tftpl`, and `observability/test_jellyfin_faro_cards.py`.
- Preserve user-owned changes to `CLAUDE.md`, `bitwarden.tf`, `.DS_Store`, `.codex/`, and `AGENTS.md`.
- Never apply a full Terraform plan. Reject any saved plan containing actionful resources outside the explicitly allowed set for that phase.
- Grafana replacement is allowed only after confirming the persistent `/var/lib/grafana` mount is unchanged. Do not restart or replace Prometheus, Traefik, Jellyfin, or the egress exporter.

## File Structure

- Modify `observability.tf`: declaratively preinstall the exact signed Business Text plugin in the existing Grafana service environment.
- Modify `observability/jellyfin-dashboard.json.tftpl`: replace only panels `4` and `9`, shorten the second dashboard row, and reflow later rows.
- Create `observability/test_jellyfin_faro_cards.py`: provide repeatable structural tests for plugin pinning, safety settings, panel markup/logic, queries, range variables, IDs, and layout.

---

### Task 1: Prove Business Text 6.3.0 on Grafana 13.1.3

**Files:**
- No tracked repository changes
- Evidence: `.superpowers/sdd/2026-08-11-jellyfin-faro-latency-cards/task-1-report.md` (ignored working report)

**Interfaces:**
- Consumes: Grafana catalog entry `marcusolsson-dynamictext-panel` version `6.3.0` and Docker image `grafana/grafana:13.1.3`.
- Produces: a hard compatibility/signed-package gate for Tasks 2–4.

- [ ] **Step 1: Verify official catalog metadata and archive checksum**

Run:

```bash
curl --fail --silent --show-error \
  https://grafana.com/api/plugins/marcusolsson-dynamictext-panel \
  -o /tmp/business-text-catalog.json
jq -e '
  .slug == "marcusolsson-dynamictext-panel" and
  .version == "6.3.0" and
  .versionStatus == "active" and
  .versionDistributionType == "catalog" and
  .versionSignedByOrg == "grafana" and
  .grafanaDependency == ">=12.3.0" and
  .packages.any.sha256 == "9e86d31dcfc6b9c7f0c8318cb313e90e29bdb71cdfca08b55058dde9747e9cb7"
' /tmp/business-text-catalog.json
curl -L --fail --silent --show-error \
  https://grafana.com/api/plugins/marcusolsson-dynamictext-panel/versions/6.3.0/download \
  -o /tmp/marcusolsson-dynamictext-panel-6.3.0.zip
printf '%s  %s\n' \
  9e86d31dcfc6b9c7f0c8318cb313e90e29bdb71cdfca08b55058dde9747e9cb7 \
  /tmp/marcusolsson-dynamictext-panel-6.3.0.zip | shasum -a 256 -c -
```

Expected: `jq` exits 0 and `shasum` prints `OK`. Stop if the catalog identity, signature owner, dependency, version, or checksum differs.

- [ ] **Step 2: Verify the disposable target name is unused**

Run:

```bash
test -z "$(docker ps -a --filter name='^/codex-grafana-business-text-compat$' --format '{{.Names}}')"
```

Expected: exit 0 with no output. Stop rather than deleting an unexpected pre-existing container.

- [ ] **Step 3: Start an isolated Grafana 13.1.3 compatibility container**

Run:

```bash
docker run --rm --detach \
  --name codex-grafana-business-text-compat \
  --publish 127.0.0.1:33001:3000 \
  --env GF_SECURITY_ADMIN_PASSWORD=compat-only \
  --env GF_PLUGINS_PREINSTALL=marcusolsson-dynamictext-panel@6.3.0 \
  grafana/grafana:13.1.3
```

Expected: prints one container ID. This container has no homelab volumes or networks.

- [ ] **Step 4: Poll health and verify the registered plugin**

Run:

```bash
for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:33001/api/health \
    | jq -e '.database == "ok" and .version == "13.1.3"' >/dev/null; then
    break
  fi
  sleep 2
done
curl --fail --silent --user admin:compat-only \
  http://127.0.0.1:33001/api/plugins/marcusolsson-dynamictext-panel/settings \
  | jq -e '
      .id == "marcusolsson-dynamictext-panel" and
      .name == "Business Text" and
      .type == "panel" and
      .info.version == "6.3.0"
    '
docker logs codex-grafana-business-text-compat 2>&1 \
  | grep -E 'marcusolsson-dynamictext-panel|Business Text'
```

Expected: health and settings assertions pass; logs show the plugin installed/registered without signature or compatibility errors.

- [ ] **Step 5: Provision a minimal Business Text panel**

Run:

```bash
curl --fail --silent --show-error \
  --user admin:compat-only \
  --header 'Content-Type: application/json' \
  --data '{
    "dashboard": {
      "id": null,
      "uid": "business-text-compat",
      "title": "Business Text compatibility",
      "schemaVersion": 39,
      "panels": [{
        "id": 1,
        "type": "marcusolsson-dynamictext-panel",
        "title": "Compatibility",
        "gridPos": {"h": 6,"w": 12,"x": 0,"y": 0},
        "options": {
          "afterRender": "",
          "content": "<div class=\"compatibility-ok\">compatibility-ok</div>",
          "defaultContent": "<div class=\"compatibility-ok\">compatibility-ok</div>",
          "editor": {"format":"auto","language":"html"},
          "editors": ["styles"],
          "renderMode": "everyRow",
          "externalStyles": [],
          "contentPartials": [],
          "helpers": "",
          "status": "",
          "styles": ".compatibility-ok { color: rgb(115, 191, 105); font-size: 24px; }",
          "wrap": false
        },
        "targets": []
      }]
    },
    "overwrite": true
  }' \
  http://127.0.0.1:33001/api/dashboards/db \
  | jq -e '.status == "success" and .uid == "business-text-compat"'
```

Expected: dashboard creation succeeds.

- [ ] **Step 6: Verify isolated browser rendering**

Open `http://127.0.0.1:33001/d/business-text-compat/business-text-compatibility`, sign in with the disposable `admin` / `compat-only` credentials, and verify:

- the panel renders `compatibility-ok` in green;
- there is no missing-plugin panel;
- browser console has no plugin load, signature, React, or sanitization error.

Capture a screenshot in the ignored task report. Stop the feature if the panel does not render correctly on Grafana 13.1.3.

- [ ] **Step 7: Stop the isolated container**

Run:

```bash
docker stop codex-grafana-business-text-compat
test -z "$(docker ps -a --filter name='^/codex-grafana-business-text-compat$' --format '{{.Names}}')"
```

Expected: Docker stops and automatically removes the `--rm` container; the final assertion is empty. No commit is made for this task.

---

### Task 2: Pin Business Text in the Grafana service

**Files:**
- Create: `observability/test_jellyfin_faro_cards.py`
- Modify: `observability.tf:204-218`

**Interfaces:**
- Consumes: the successful Task 1 compatibility gate and plugin ID/version `marcusolsson-dynamictext-panel@6.3.0`.
- Produces: a Terraform-managed Grafana environment that installs the exact signed panel on every container creation.

- [ ] **Step 1: Write the failing infrastructure tests**

Create `observability/test_jellyfin_faro_cards.py` with:

```python
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OBSERVABILITY_TF = ROOT / "observability.tf"
DASHBOARD_TEMPLATE = ROOT / "observability" / "jellyfin-dashboard.json.tftpl"
PLUGIN_ENV = "GF_PLUGINS_PREINSTALL=marcusolsson-dynamictext-panel@6.3.0"


def load_dashboard():
    rendered = DASHBOARD_TEMPLATE.read_text().replace(
        "${datasource_uid}", "test-prometheus"
    )
    return json.loads(rendered)


class GrafanaPluginConfigurationTests(unittest.TestCase):
    def test_business_text_is_pinned_once(self):
        source = OBSERVABILITY_TF.read_text()
        self.assertEqual(source.count(PLUGIN_ENV), 1)

    def test_unsafe_html_and_unsigned_plugins_remain_disabled(self):
        source = OBSERVABILITY_TF.read_text()
        self.assertNotIn("GF_PANELS_DISABLE_SANITIZE_HTML", source)
        self.assertNotIn("GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS", source)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the focused test to verify RED**

Run:

```bash
python3 -m unittest -v \
  observability.test_jellyfin_faro_cards.GrafanaPluginConfigurationTests
```

Expected: `test_business_text_is_pinned_once` fails with `0 != 1`; the safety test passes.

- [ ] **Step 3: Add the pinned plugin to Grafana's environment**

In `module "grafana"`, change the environment list to exactly:

```hcl
env = concat(local.shared_env, [
  "GF_SECURITY_ADMIN_PASSWORD=${var.password}",
  "GF_SERVER_ROOT_URL=http://grafana.localdomain",
  "GF_PLUGINS_PREINSTALL=marcusolsson-dynamictext-panel@6.3.0",
])
```

Do not change the image, user, networks, or volume.

- [ ] **Step 4: Run the focused tests to verify GREEN**

Run:

```bash
python3 -m unittest -v \
  observability.test_jellyfin_faro_cards.GrafanaPluginConfigurationTests
terraform fmt -check
terraform validate -no-color
git diff --check
```

Expected: both tests pass; Terraform formatting/validation and diff checks pass. The known Home Assistant development-override warning is acceptable; any error is not.

- [ ] **Step 5: Review and commit Task 2**

Run:

```bash
git diff -- observability.tf observability/test_jellyfin_faro_cards.py
git add observability.tf observability/test_jellyfin_faro_cards.py
git diff --cached --check
git commit -m "Preinstall Grafana Business Text panel"
```

Expected: the commit contains only the Grafana environment entry and the initial test file.

---

### Task 3: Render p95 and p99 as Faro-style cards

**Files:**
- Modify: `observability/jellyfin-dashboard.json.tftpl:88-193`
- Modify: `observability/test_jellyfin_faro_cards.py`

**Interfaces:**
- Consumes: Business Text panel type `marcusolsson-dynamictext-panel`, per-row Prometheus field `Value` in seconds, and the existing p95/p99 instant queries.
- Produces: panel IDs `4` and `9` with identical Faro markup/logic/styles, distinct queries, and compact non-overlapping layout.

- [ ] **Step 1: Add failing dashboard-structure tests**

Insert the following class before the `if __name__ == "__main__"` block in `observability/test_jellyfin_faro_cards.py`:

```python
class FaroLatencyDashboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboard = load_dashboard()
        cls.panels = {panel["id"]: panel for panel in cls.dashboard["panels"]}

    def test_dashboard_keeps_fourteen_unique_panels(self):
        ids = [panel["id"] for panel in self.dashboard["panels"]]
        self.assertEqual(len(ids), 14)
        self.assertEqual(len(set(ids)), 14)

    def test_latency_panels_use_business_text_and_exact_queries(self):
        expected = {
            4: "histogram_quantile(0.95, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router=\"jellyfin@docker\"}[$__range])))",
            9: "histogram_quantile(0.99, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router=\"jellyfin@docker\"}[$__range])))",
        }
        for panel_id, expression in expected.items():
            with self.subTest(panel_id=panel_id):
                panel = self.panels[panel_id]
                self.assertEqual(panel["type"], "marcusolsson-dynamictext-panel")
                self.assertEqual(panel["targets"], [{
                    "refId": "A",
                    "expr": expression,
                    "instant": True,
                }])
                self.assertNotIn("timeFrom", panel)
                self.assertNotIn("timeShift", panel)

    def test_latency_cards_contain_faro_value_meter_and_indicators(self):
        required_content = (
            "jf-latency-value",
            "jf-latency-quality",
            "jf-latency-meter__fill",
            "jf-latency-meter__pointer",
            "jf-latency-tick--one",
            "jf-latency-tick--two",
            "1 s",
            "2 s",
        )
        required_logic = (
            "context.data?.Value",
            "typeof raw === 'number'",
            "seconds < 1",
            "seconds < 2",
            "Needs improvement",
            "Math.min(5, Math.max(0, seconds)) / 5 * 100",
            "--latency-position",
        )
        for panel_id in (4, 9):
            with self.subTest(panel_id=panel_id):
                options = self.panels[panel_id]["options"]
                self.assertEqual(options["renderMode"], "everyRow")
                self.assertFalse(options["wrap"])
                self.assertEqual(options["externalStyles"], [])
                self.assertEqual(options["contentPartials"], [])
                for token in required_content:
                    self.assertIn(token, options["content"])
                for token in required_logic:
                    self.assertIn(token, options["afterRender"])
                self.assertIn("No data", options["defaultContent"])
                self.assertIn("--good: rgb(115, 191, 105)", options["styles"])
                self.assertIn("--warning: rgb(255, 152, 48)", options["styles"])
                self.assertIn("--poor: rgb(242, 73, 92)", options["styles"])

    def test_compact_grid_has_no_overlap(self):
        expected_grid = {
            8: {"h": 5, "w": 12, "x": 0, "y": 9},
            4: {"h": 5, "w": 6, "x": 12, "y": 9},
            9: {"h": 5, "w": 6, "x": 18, "y": 9},
            5: {"h": 5, "w": 3, "x": 0, "y": 14},
            10: {"h": 5, "w": 3, "x": 3, "y": 14},
            11: {"h": 5, "w": 3, "x": 6, "y": 14},
            12: {"h": 5, "w": 3, "x": 9, "y": 14},
            13: {"h": 5, "w": 3, "x": 12, "y": 14},
            14: {"h": 5, "w": 3, "x": 15, "y": 14},
            15: {"h": 5, "w": 3, "x": 18, "y": 14},
            16: {"h": 5, "w": 3, "x": 21, "y": 14},
            3: {"h": 8, "w": 24, "x": 0, "y": 19},
        }
        for panel_id, grid in expected_grid.items():
            self.assertEqual(self.panels[panel_id]["gridPos"], grid)

        panels = self.dashboard["panels"]
        for index, left in enumerate(panels):
            for right in panels[index + 1:]:
                a, b = left["gridPos"], right["gridPos"]
                overlap = not (
                    a["x"] + a["w"] <= b["x"]
                    or b["x"] + b["w"] <= a["x"]
                    or a["y"] + a["h"] <= b["y"]
                    or b["y"] + b["h"] <= a["y"]
                )
                self.assertFalse(overlap, f"panels {left['id']} and {right['id']} overlap")

    def test_all_dashboard_range_variables_are_preserved(self):
        for panel in self.dashboard["panels"]:
            for target in panel.get("targets", []):
                expression = target["expr"]
                if panel["type"] == "timeseries":
                    self.assertIn("[$__rate_interval]", expression)
                else:
                    self.assertIn("[$__range]", expression)
```

- [ ] **Step 2: Run the dashboard tests to verify RED**

Run:

```bash
python3 -m unittest -v \
  observability.test_jellyfin_faro_cards.FaroLatencyDashboardTests
```

Expected: failures show panels `4` and `9` are still `bargauge`, Faro options are absent, and the old row positions differ.

- [ ] **Step 3: Define the exact shared Business Text options on both latency panels**

Replace the `options` object on both panel `4` and panel `9` with this exact object; JSON-escape newlines and quotes as required by the template:

```json
{
  "afterRender": "const root = context.element.querySelector('.jf-latency-card');\nconst raw = context.data?.Value;\nconst seconds = typeof raw === 'number' ? raw : Number.NaN;\nif (!root || !Number.isFinite(seconds)) { return; }\nconst quality = seconds < 1 ? 'good' : seconds < 2 ? 'warning' : 'poor';\nconst label = quality === 'good' ? 'Good' : quality === 'warning' ? 'Needs improvement' : 'Poor';\nconst display = seconds < 1 ? `${Math.round(seconds * 1000)} ms` : `${seconds.toFixed(seconds < 10 ? 2 : 1)} s`;\nconst position = Math.min(5, Math.max(0, seconds)) / 5 * 100;\nroot.dataset.quality = quality;\nroot.style.setProperty('--latency-position', `${position}%`);\nroot.querySelector('.jf-latency-value').textContent = display;\nroot.querySelector('.jf-latency-quality').textContent = `(${label})`;",
  "content": "<div class=\"jf-latency-card\"><div class=\"jf-latency-reading\"><span class=\"jf-latency-value\">No data</span> <span class=\"jf-latency-quality\"></span></div><div class=\"jf-latency-meter\"><span class=\"jf-latency-meter__pointer\"></span><div class=\"jf-latency-meter__track\"><span class=\"jf-latency-meter__fill\"></span></div><span class=\"jf-latency-tick jf-latency-tick--one\"><i></i><b>1 s</b></span><span class=\"jf-latency-tick jf-latency-tick--two\"><i></i><b>2 s</b></span></div></div>",
  "defaultContent": "<div class=\"jf-latency-card jf-latency-card--empty\"><div class=\"jf-latency-reading\"><span class=\"jf-latency-value\">No data</span></div><div class=\"jf-latency-meter\"><div class=\"jf-latency-meter__track\"></div><span class=\"jf-latency-tick jf-latency-tick--one\"><i></i><b>1 s</b></span><span class=\"jf-latency-tick jf-latency-tick--two\"><i></i><b>2 s</b></span></div></div>",
  "editor": { "format": "auto", "language": "html" },
  "editors": ["afterRender", "styles"],
  "renderMode": "everyRow",
  "externalStyles": [],
  "contentPartials": [],
  "helpers": "",
  "status": "",
  "styles": ".jf-latency-card { --good: rgb(115, 191, 105); --warning: rgb(255, 152, 48); --poor: rgb(242, 73, 92); --status-color: currentColor; --latency-position: 0%; box-sizing: border-box; display: flex; flex-direction: column; justify-content: center; height: 100%; padding: 8px 10px 18px; }\n.jf-latency-card[data-quality=\"good\"] { --status-color: var(--good); }\n.jf-latency-card[data-quality=\"warning\"] { --status-color: var(--warning); }\n.jf-latency-card[data-quality=\"poor\"] { --status-color: var(--poor); }\n.jf-latency-card--empty { opacity: 0.7; }\n.jf-latency-reading { color: var(--status-color); font-size: 24px; font-weight: 600; line-height: 1.25; margin-bottom: 12px; white-space: nowrap; }\n.jf-latency-quality { font-size: 14px; font-weight: 400; }\n.jf-latency-meter { height: 36px; position: relative; }\n.jf-latency-meter__track { background: rgba(204, 204, 220, 0.16); height: 8px; left: 0; overflow: hidden; position: absolute; right: 0; top: 8px; }\n.jf-latency-meter__fill { background: var(--status-color); display: block; height: 100%; width: var(--latency-position); }\n.jf-latency-meter__pointer { border-left: 5px solid transparent; border-right: 5px solid transparent; border-top: 7px solid var(--status-color); left: var(--latency-position); position: absolute; top: 0; transform: translateX(-50%); }\n.jf-latency-tick { color: currentColor; font-size: 11px; position: absolute; top: 8px; transform: translateX(-50%); }\n.jf-latency-tick i { background: currentColor; display: block; height: 12px; margin: 0 auto 2px; opacity: 0.75; width: 1px; }\n.jf-latency-tick b { font-weight: 400; white-space: nowrap; }\n.jf-latency-tick--one { left: 20%; }\n.jf-latency-tick--two { left: 40%; }",
  "wrap": false
}
```

Do not add external resources or global Grafana CSS/settings.

- [ ] **Step 4: Replace panel 4 and panel 9 types while preserving their queries**

For panel `4`, require these exact non-option fields:

```json
{
  "id": 4,
  "type": "marcusolsson-dynamictext-panel",
  "title": "p95 latency",
  "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
  "gridPos": { "h": 5, "w": 6, "x": 12, "y": 9 },
  "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] },
  "targets": [{
    "refId": "A",
    "expr": "histogram_quantile(0.95, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router=\"jellyfin@docker\"}[$__range])))",
    "instant": true
  }]
}
```

For panel `9`, require these exact non-option fields:

```json
{
  "id": 9,
  "type": "marcusolsson-dynamictext-panel",
  "title": "p99 latency",
  "datasource": { "type": "prometheus", "uid": "${datasource_uid}" },
  "gridPos": { "h": 5, "w": 6, "x": 18, "y": 9 },
  "fieldConfig": { "defaults": { "unit": "s" }, "overrides": [] },
  "targets": [{
    "refId": "A",
    "expr": "histogram_quantile(0.99, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router=\"jellyfin@docker\"}[$__range])))",
    "instant": true
  }]
}
```

Each object also contains the complete shared `options` object from Step 3. Do not retain Bar Gauge min/max/options; the meter's 0–5 scale is implemented by the after-render calculation and fixed tick positions.

- [ ] **Step 5: Compact and reflow the affected dashboard rows**

Apply these exact `gridPos` changes and no others:

```text
panel 8:  {"h":5,"w":12,"x":0,"y":9}
panel 5:  {"h":5,"w":3,"x":0,"y":14}
panel 10: {"h":5,"w":3,"x":3,"y":14}
panel 11: {"h":5,"w":3,"x":6,"y":14}
panel 12: {"h":5,"w":3,"x":9,"y":14}
panel 13: {"h":5,"w":3,"x":12,"y":14}
panel 14: {"h":5,"w":3,"x":15,"y":14}
panel 15: {"h":5,"w":3,"x":18,"y":14}
panel 16: {"h":5,"w":3,"x":21,"y":14}
panel 3:  {"h":8,"w":24,"x":0,"y":19}
```

Panels `1` and `2` remain unchanged. Panel `8` retains its query, transformations, columns, sort, and field override.

- [ ] **Step 6: Run dashboard tests to verify GREEN**

Run:

```bash
python3 -m unittest -v observability.test_jellyfin_faro_cards
python3 -m py_compile observability/test_jellyfin_faro_cards.py
if test -d observability/__pycache__; then
  rm -r -- observability/__pycache__
fi
sed 's/${datasource_uid}/test-prometheus/g' \
  observability/jellyfin-dashboard.json.tftpl | jq -e . >/dev/null
terraform fmt -check
terraform validate -no-color
git diff --check
```

Expected: every unit test and JSON check passes; Terraform validation has no error.

- [ ] **Step 7: Review and commit Task 3**

Run:

```bash
git diff -- observability/jellyfin-dashboard.json.tftpl \
  observability/test_jellyfin_faro_cards.py
git add observability/jellyfin-dashboard.json.tftpl \
  observability/test_jellyfin_faro_cards.py
git diff --cached --check
git commit -m "Render Jellyfin latency as Faro cards"
```

Expected: the commit contains only the dashboard and expanded tests.

---

### Task 4: Deploy the plugin and cards through isolated saved plans

**Files:**
- No tracked repository changes expected
- Evidence: `.superpowers/sdd/2026-08-11-jellyfin-faro-latency-cards/task-4-report.md` (ignored working report)

**Interfaces:**
- Consumes: committed Tasks 2–3, live Grafana state, folder UID `afu9hvo3v3g8wa`, and Prometheus datasource UID `prometheus`.
- Produces: one reviewed Grafana container replacement, one dashboard-only update, authenticated rendering evidence, and no-change convergence plans.

- [ ] **Step 1: Capture live and repository baselines**

Run:

```bash
git status --short
git diff --check
python3 -m unittest -v observability.test_jellyfin_faro_cards
terraform fmt -check
terraform validate -no-color
curl --fail --silent http://grafana.localdomain/api/health \
  | jq -e '.database == "ok" and .version == "13.1.3"'
docker inspect grafana \
  --format '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Source}} -> {{.Destination}}{{end}}{{end}}'
```

Expected: tests and validation pass; Grafana is healthy; the mount is `/home/reilley/appdata/grafana -> /var/lib/grafana`. Stop if the mount differs or the worktree has overlapping uncommitted changes.

- [ ] **Step 2: Create and inspect the Grafana-only saved plan**

Run:

```bash
terraform plan -no-color \
  -target=module.grafana \
  -out=/tmp/jellyfin-faro-grafana.tfplan
terraform show -json /tmp/jellyfin-faro-grafana.tfplan \
  | jq -e '[
      .resource_changes[] |
      select(.change.actions != ["no-op"]) |
      {address, actions: .change.actions}
    ] == [{
      "address":"module.grafana.docker_container.container",
      "actions":["delete","create"]
    }]'
```

Expected: only the Grafana container is replaced for the environment change. Stop if an image, network, DNS record, another container, or any other resource is actionful; do not absorb mutable-image drift.

- [ ] **Step 3: Apply only the reviewed Grafana plan**

Run:

```bash
terraform apply -no-color /tmp/jellyfin-faro-grafana.tfplan
```

Expected: `1 added, 0 changed, 1 destroyed`, naming only `module.grafana.docker_container.container`. Brief Grafana dashboard downtime is expected.

- [ ] **Step 4: Verify Grafana recovery and plugin registration**

Run:

```bash
for attempt in $(seq 1 30); do
  if curl --fail --silent http://grafana.localdomain/api/health \
    | jq -e '.database == "ok" and .version == "13.1.3"' >/dev/null; then
    break
  fi
  sleep 2
done
docker exec grafana cat \
  /var/lib/grafana/plugins/marcusolsson-dynamictext-panel/plugin.json \
  | jq -e '
      .id == "marcusolsson-dynamictext-panel" and
      .type == "panel" and
      .info.version == "6.3.0" and
      .dependencies.grafanaDependency == ">=12.3.0"
    '
docker exec grafana test -f \
  /var/lib/grafana/plugins/marcusolsson-dynamictext-panel/MANIFEST.txt
docker logs grafana 2>&1 \
  | grep -E 'marcusolsson-dynamictext-panel|Business Text'
```

Expected: health returns, plugin version `6.3.0` is registered, and logs contain no signature or compatibility error. Stop before dashboard deployment if this gate fails.

- [ ] **Step 5: Temporarily cut only dashboard transitive dependencies**

First verify live state still matches the approved literals:

```bash
terraform state show grafana_folder.homelab | grep 'uid.*=.*"afu9hvo3v3g8wa"'
terraform state show grafana_data_source.prometheus | grep 'uid.*=.*"prometheus"'
```

Then temporarily replace exactly:

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

Do not alter any other expression.

- [ ] **Step 6: Create and inspect the dashboard-only saved plan**

Run:

```bash
terraform plan -no-color \
  -target=grafana_dashboard.jellyfin \
  -out=/tmp/jellyfin-faro-dashboard.tfplan
terraform show -json /tmp/jellyfin-faro-dashboard.tfplan \
  | jq -e '[
      .resource_changes[] |
      select(.change.actions != ["no-op"]) |
      {address, actions: .change.actions}
    ] == [{
      "address":"grafana_dashboard.jellyfin",
      "actions":["update"]
    }]'
```

Expected: only `grafana_dashboard.jellyfin` updates in place.

- [ ] **Step 7: Restore `observability.tf` before applying**

Restore the two exact committed expressions from Step 5, then run:

```bash
terraform fmt -check
git diff --exit-code -- observability.tf
git diff --check
```

Expected: `observability.tf` has no diff. Never apply while the temporary dependency cut remains.

- [ ] **Step 8: Apply only the reviewed dashboard plan**

Run:

```bash
terraform apply -no-color /tmp/jellyfin-faro-dashboard.tfplan
```

Expected: `0 added, 1 changed, 0 destroyed`, naming only `grafana_dashboard.jellyfin`.

- [ ] **Step 9: Verify authenticated live rendering and indicators**

Open:

```text
http://grafana.localdomain/d/jellyfin/jellyfin?from=now-24h&to=now
```

Verify both p95 and p99 cards show:

- the numeric value and `ms` or `s` unit together above the meter;
- `(Good)`, `(Needs improvement)`, or `(Poor)` beside the value;
- a thin left-to-right horizontal meter rather than a tall slab;
- a triangular pointer aligned with the end of the fill;
- visible threshold ticks labelled `1 s` at 20% and `2 s` at 40%;
- green below 1 second, amber from 1 to below 2 seconds, and red at 2 seconds or above.

Also verify the Egress-by-user table still shows User/Egress in descending order, all eight status cards remain separate, and both time-series panels render.

Change the range to `Last 1 hour`, then `Last 5 minutes`. Confirm both latency cards rerender from the selected range. A genuinely empty range must show `No data`, not `0 ms (Good)`. Capture screenshots and browser-console results in the ignored task report.

- [ ] **Step 10: Run isolated convergence plans**

Run the Grafana convergence gate:

```bash
terraform plan -no-color \
  -target=module.grafana \
  -out=/tmp/jellyfin-faro-grafana-converged.tfplan
terraform show -json /tmp/jellyfin-faro-grafana-converged.tfplan \
  | jq -e '[.resource_changes[] | select(.change.actions != ["no-op"])] == []'
```

Repeat the exact temporary dashboard dependency cut from Step 5, then run:

```bash
terraform plan -no-color \
  -target=grafana_dashboard.jellyfin \
  -out=/tmp/jellyfin-faro-dashboard-converged.tfplan
terraform show -json /tmp/jellyfin-faro-dashboard-converged.tfplan \
  | jq -e '[.resource_changes[] | select(.change.actions != ["no-op"])] == []'
```

Restore the two committed dashboard expressions and require:

```bash
git diff --exit-code -- observability.tf
```

Expected: both actionful sets are empty and `observability.tf` is restored exactly.

- [ ] **Step 11: Run final verification**

Run:

```bash
python3 -m unittest -v observability.test_jellyfin_faro_cards
python3 -m py_compile observability/test_jellyfin_faro_cards.py
if test -d observability/__pycache__; then
  rm -r -- observability/__pycache__
fi
sed 's/${datasource_uid}/test-prometheus/g' \
  observability/jellyfin-dashboard.json.tftpl | jq -e . >/dev/null
terraform fmt -check
terraform validate -no-color
git diff --check
git status --short
```

Expected: all checks pass; no `__pycache__` directory remains; status contains only the pre-existing user-owned changes. Do not run or apply a full Terraform plan.

#### Failure-only rollback

If Grafana does not recover, the signed plugin does not register, or the live cards fail the rendering gates, stop forward work and restore only the two managed files to the last pre-feature commit:

```bash
git restore --source=1c58758 -- observability.tf \
  observability/jellyfin-dashboard.json.tftpl
git rm observability/test_jellyfin_faro_cards.py
git diff --check
git commit -m "Roll back Faro-style Jellyfin latency cards"
```

Generate and inspect a Grafana-only rollback plan and a dependency-cut dashboard-only rollback plan using the same exact actionful-resource gates from Steps 2 and 6. Apply only those reviewed saved plans. After Grafana recovers without the preinstall setting, remove the persisted plugin with the supported CLI and verify it is absent:

```bash
docker exec grafana grafana cli plugins remove marcusolsson-dynamictext-panel
test ! -e /home/reilley/appdata/grafana/plugins/marcusolsson-dynamictext-panel
```

Then rerun health, dashboard rendering, Terraform convergence, and repository checks. Do not perform this rollback on a successful deployment.

---

## Completion Criteria

1. Business Text `6.3.0` is checksum-verified, catalog-signed by Grafana Labs, and proven to load/render on Grafana 13.1.3 before live replacement.
2. Grafana declaratively preinstalls exactly `marcusolsson-dynamictext-panel@6.3.0` without unsafe HTML or unsigned plugins.
3. p95 and p99 retain their exact PromQL and follow `$__range`.
4. Each latency card places its value and unit above a thin horizontal meter.
5. Each card has a moving triangular pointer plus labelled `1 s` and `2 s` threshold ticks.
6. Good/Needs improvement/Poor labels and green/amber/red colours follow the exact 1-second and 2-second thresholds.
7. Missing data renders `No data`; the visual position clamps to 0–5 seconds without changing the displayed value.
8. The dashboard still contains fourteen unique, non-overlapping panels; all non-latency panels and range semantics are preserved.
9. The only live infrastructure mutation is the reviewed Grafana container replacement; the only dashboard mutation is the reviewed in-place `grafana_dashboard.jellyfin` update.
10. Unit tests, JSON parsing, Terraform formatting/validation, authenticated rendering, browser-console checks, range switching, and both isolated convergence plans pass.
