# Jellyfin Dashboard Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the eight redundant HTTP status-code cards and reorganize the six retained Jellyfin panels into a clear summary-and-trends layout with two full-width graphs.

**Architecture:** Delete only panels 5 and 10–16 from the Terraform-managed dashboard JSON, then change only `gridPos` on the six retained panels. Protect the retained queries and Faro card behavior with executable Python tests, and deploy through an isolated saved Terraform plan whose only actionful resource is `grafana_dashboard.jellyfin`.

**Tech Stack:** Terraform, Grafana 13.1.3, Business Text 6.3.0, Grafana dashboard JSON schema 39, Prometheus/PromQL, Python `unittest`, `jq`, authenticated in-app browser verification.

## Global Constraints

- Keep exactly panel IDs `1`, `2`, `3`, `4`, `8`, and `9`; remove panel IDs `5`, `10`, `11`, `12`, `13`, `14`, `15`, and `16` without replacement.
- Use this exact grid: p95 `{x:0,y:0,w:12,h:4}`, p99 `{x:12,y:0,w:12,h:4}`, Public egress `{x:0,y:4,w:6,h:6}`, Egress by user `{x:6,y:4,w:18,h:6}`, Public response accounting rate `{x:0,y:10,w:24,h:10}`, Request rate public vs LAN `{x:0,y:20,w:24,h:10}`.
- Preserve both Faro latency panels exactly except for their unchanged grid positions: three exclusive zones, neutral pointer, visible value/quality spacing, raw numeric handling, thresholds, no-data reset, and 0–3 second scale.
- Preserve the exact PromQL, datasource, legend, field configuration, transformations, units, descriptions, and options of all six retained panels; change only their grid positions.
- Preserve `$__range` for summary/table/latency queries and `$__rate_interval` for both time-series queries.
- Preserve dashboard default time, refresh, tags, title, UID, schema version, and editable setting.
- Expected tracked implementation changes are limited to `observability/jellyfin-dashboard.json.tftpl`, `observability/test_jellyfin_faro_cards.py`, and this plan.
- Preserve user-owned changes to `CLAUDE.md`, `.DS_Store`, `.codex/`, and `AGENTS.md`.
- Never run or apply a broad Terraform plan; reject any saved plan with an actionful resource other than an in-place update to `grafana_dashboard.jellyfin`.
- Do not replace or restart Grafana or any other container.

## File Structure

- Modify `observability/jellyfin-dashboard.json.tftpl`: remove only the eight status-code panel objects and set exact `gridPos` values on the retained six panels.
- Modify `observability/test_jellyfin_faro_cards.py`: assert retained panel identity, removal of code-specific queries, exact retained queries, exact grid, non-overlap, range behavior, and unchanged Faro behavior.
- Create `.superpowers/sdd/2026-08-11-jellyfin-dashboard-simplification/task-1-report.md`: ignored RED/GREEN and implementation evidence.
- Create `.superpowers/sdd/2026-08-11-jellyfin-dashboard-simplification/task-2-report.md`: ignored deployment, browser, and convergence evidence.

---

### Task 1: Remove status cards and implement the six-panel layout

**Files:**
- Modify: `observability/test_jellyfin_faro_cards.py`
- Modify: `observability/jellyfin-dashboard.json.tftpl`
- Evidence: `.superpowers/sdd/2026-08-11-jellyfin-dashboard-simplification/task-1-report.md`

**Interfaces:**
- Consumes: `load_dashboard()` and the existing panel dictionary keyed by integer ID.
- Produces: a dashboard containing only panel IDs `{1, 2, 3, 4, 8, 9}`, with exact retained queries and the six-panel non-overlapping grid.

- [ ] **Step 1: Write failing panel-inventory tests**

Replace `test_dashboard_keeps_fourteen_unique_panels` with:

```python
def test_dashboard_keeps_exactly_the_six_useful_panels(self):
    ids = [panel["id"] for panel in self.dashboard["panels"]]
    self.assertEqual(ids, [1, 2, 8, 4, 9, 3])
    self.assertEqual(len(ids), 6)
    self.assertEqual(len(set(ids)), 6)
```

The list order is the existing JSON order after the eight status objects are removed; it does not change Grafana grid ordering.

Add this removal regression:

```python
def test_http_status_cards_and_dedicated_code_queries_are_removed(self):
    removed_ids = {5, 10, 11, 12, 13, 14, 15, 16}
    removed_titles = {"200", "204", "302", "304", "404", "499", "502", "Other"}
    self.assertTrue(removed_ids.isdisjoint(self.panels))
    self.assertTrue(
        removed_titles.isdisjoint(panel["title"] for panel in self.dashboard["panels"])
    )
    for panel in self.dashboard["panels"]:
        for target in panel.get("targets", []):
            self.assertNotRegex(target["expr"], r'code(?:=|!~)')
```

- [ ] **Step 2: Write failing retained-query and layout tests**

Add exact query/type assertions for the four non-latency panels:

```python
def test_retained_non_latency_panels_keep_exact_queries_and_types(self):
    expected = {
        1: (
            "timeseries",
            'sum(rate(traefik_router_responses_bytes_total{router="jellyfin@docker"}[$__rate_interval])) * 8',
        ),
        2: (
            "stat",
            'sum(increase(traefik_router_responses_bytes_total{router="jellyfin@docker"}[$__range]))',
        ),
        3: (
            "timeseries",
            'sum by (router) (rate(traefik_router_requests_total{router=~"jellyfin(local)?@docker"}[$__rate_interval]))',
        ),
        8: (
            "table",
            'sort_desc(sum by (user) (increase(jellyfin_user_egress_bytes_v2_total[$__range])))',
        ),
    }
    for panel_id, (panel_type, expression) in expected.items():
        with self.subTest(panel_id=panel_id):
            panel = self.panels[panel_id]
            self.assertEqual(panel["type"], panel_type)
            self.assertEqual(len(panel["targets"]), 1)
            self.assertEqual(panel["targets"][0]["expr"], expression)
```

Replace the expected grid in `test_compact_grid_has_no_overlap` with:

```python
expected_grid = {
    4: {"h": 4, "w": 12, "x": 0, "y": 0},
    9: {"h": 4, "w": 12, "x": 12, "y": 0},
    2: {"h": 6, "w": 6, "x": 0, "y": 4},
    8: {"h": 6, "w": 18, "x": 6, "y": 4},
    1: {"h": 10, "w": 24, "x": 0, "y": 10},
    3: {"h": 10, "w": 24, "x": 0, "y": 20},
}
```

Retain the exhaustive pairwise overlap loop and all existing latency behavior, plugin-safety, template-interpolation, and range-variable tests.

- [ ] **Step 3: Run focused tests to establish RED**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_jellyfin_faro_cards
```

Expected: failures report fourteen panels instead of six, status-card IDs/titles/code queries still present, and old grid positions. The retained-query assertions should pass before implementation; record that mixed result because it proves the preservation baseline.

- [ ] **Step 4: Remove only the eight HTTP status panel objects**

In `observability/jellyfin-dashboard.json.tftpl`, delete the complete JSON objects with IDs `5`, `10`, `11`, `12`, `13`, `14`, `15`, and `16`, including their code-specific PromQL targets. Repair only the surrounding array commas so the template remains valid JSON.

Do not change the contents of panels `1`, `2`, `3`, `4`, `8`, or `9` in this step.

- [ ] **Step 5: Apply the exact six-panel grid**

Change only `gridPos` on the retained panels to:

```text
panel 4:  { "h": 4,  "w": 12, "x": 0,  "y": 0 }
panel 9:  { "h": 4,  "w": 12, "x": 12, "y": 0 }
panel 2:  { "h": 6,  "w": 6,  "x": 0,  "y": 4 }
panel 8:  { "h": 6,  "w": 18, "x": 6,  "y": 4 }
panel 1:  { "h": 10, "w": 24, "x": 0,  "y": 10 }
panel 3:  { "h": 10, "w": 24, "x": 0,  "y": 20 }
```

Do not reorder retained objects or change any other retained panel property.

- [ ] **Step 6: Run focused tests to establish GREEN**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_jellyfin_faro_cards
```

Expected: all focused tests pass, including exact inventory, absent status queries, exact retained queries, exact layout, pairwise non-overlap, Faro behavior, and range semantics.

- [ ] **Step 7: Run full implementation verification**

Run separately:

```bash
PYTHONPATH=observability python3 -m unittest discover -s observability -p 'test_*.py' -v
python3 -m py_compile observability/test_jellyfin_faro_cards.py
terraform fmt -check
terraform validate -no-color
git diff --check
```

Render the dashboard template with the same substitutions as `load_dashboard()` and require valid JSON with exactly six panels. Remove only generated `observability/__pycache__`. Expected: all tests and checks pass; Terraform validation may emit only the existing Home Assistant provider development-override warning.

- [ ] **Step 8: Self-review and commit Task 1**

Verify the diff changes only the dashboard template and Faro tests. Confirm that retained panel JSON differs from its base only at `gridPos`, removed panel IDs are exactly the required eight, no query outside a removed panel changed, and no new feature was introduced.

Commit:

```bash
git add observability/jellyfin-dashboard.json.tftpl observability/test_jellyfin_faro_cards.py
git commit -m "Simplify Jellyfin dashboard layout"
```

Record RED/GREEN evidence, preservation comparison, commands, commit, and user-owned status in `task-1-report.md`.

---

### Task 2: Deploy and verify the six-panel dashboard

**Files:**
- No tracked repository changes
- Evidence: `.superpowers/sdd/2026-08-11-jellyfin-dashboard-simplification/task-2-report.md`

**Interfaces:**
- Consumes: the reviewed Task 1 commit and current Terraform state.
- Produces: a deployed six-panel dashboard, authenticated range screenshots, and an empty isolated convergence plan without replacing any container.

- [ ] **Step 1: Establish preflight and dependency literals**

Record `git status --short`, `git diff --check`, `terraform fmt -check`, `terraform validate -no-color`, and focused tests. Require no Terraform lock, no `observability/__pycache__`, and no diff in `observability.tf`.

Read Terraform state and require the current folder and Prometheus datasource UIDs before using them as temporary dependency literals. Stop rather than guessing if they differ from the current state.

- [ ] **Step 2: Create and gate an isolated saved plan**

Use `apply_patch` to temporarily replace only `grafana_dashboard.jellyfin`'s folder and datasource expressions with the exact UIDs read in Step 1.

Run:

```bash
terraform plan -target=grafana_dashboard.jellyfin -out=/tmp/jellyfin-dashboard-simplification.tfplan
terraform show -json /tmp/jellyfin-dashboard-simplification.tfplan > /tmp/jellyfin-dashboard-simplification.tfplan.json
jq -e '[.resource_changes[] | select(.change.actions != ["no-op"]) | {address, actions: .change.actions}] == [{"address":"grafana_dashboard.jellyfin","actions":["update"]}]' /tmp/jellyfin-dashboard-simplification.tfplan.json
```

Expected: the gate returns `true`. Structurally compare before/after dashboard JSON and require exactly the eight specified panel removals plus the six specified `gridPos` changes; every other retained panel and dashboard property must be equal. Stop on any container, provider, query, option, datasource, or unrelated change.

- [ ] **Step 3: Restore committed Terraform before apply**

Use `apply_patch` to restore the original folder and datasource expressions. Run `terraform fmt -check`, `git diff --exit-code -- observability.tf`, `git diff --check`, and verify no Terraform lock. Stop unless `observability.tf` is exact.

- [ ] **Step 4: Apply only the gated saved plan**

Run:

```bash
terraform apply -no-color /tmp/jellyfin-dashboard-simplification.tfplan
```

Expected: `0 added, 1 changed, 0 destroyed`, modifying only `grafana_dashboard.jellyfin`. Run no other apply.

- [ ] **Step 5: Verify deployed state**

Export current Terraform state as JSON and assert exactly six panel IDs, exact grid positions, absent status titles/code queries, unchanged retained queries/options, unchanged dashboard settings, and preserved Faro markup/CSS/JavaScript.

- [ ] **Step 6: Verify authenticated rendering at 24 hours, 1 hour, and 5 minutes**

In the authenticated in-app browser, confirm at each range:

- exactly six panel regions render and no HTTP status card remains;
- latency cards share the top row;
- Public egress and Egress by user share the second row at one-quarter/three-quarter widths;
- each graph is full-width and ten grid rows high;
- table sorting, public egress value, latency state, graph legends, and range-driven values render normally;
- the console has no Business Text, JavaScript, React, template, or datasource errors.

Capture a 24-hour full dashboard screenshot and representative 1-hour and 5-minute screenshots. Do not alter queries or fabricate data when a range is genuinely empty.

- [ ] **Step 7: Prove convergence without applying it**

Repeat only the two temporary dependency cuts, save `/tmp/jellyfin-dashboard-simplification-converged.tfplan`, export its JSON, and restore `observability.tf` before interpreting the result. Require:

```bash
jq -e '[.resource_changes[] | select(.change.actions != ["no-op"])] == []' /tmp/jellyfin-dashboard-simplification-converged.tfplan.json
```

Expected: Terraform reports no changes and the actionful set is empty. Never apply the convergence plan.

- [ ] **Step 8: Run final repository gates**

Run the full observability suite, focused tests, `py_compile`, rendered-template JSON parsing, `terraform fmt -check`, `terraform validate -no-color`, and `git diff --check`. Require no `observability.tf` diff, Terraform lock, or `observability/__pycache__`, and preserve the pre-existing user-owned status. Record plan/apply/state/browser/convergence/test evidence in `task-2-report.md`; make no deployment commit.
