# Jellyfin Faro Meter Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the p95 and p99 latency cards into a compact top row and reproduce Faro's three-zone threshold meter with only the current value's zone highlighted.

**Architecture:** Keep Business Text 6.3.0, the existing raw Prometheus values, and the exact range-scoped p95/p99 queries. Change only the dashboard template and its executable regression tests, then deploy through an isolated saved Terraform plan whose only actionful resource is `grafana_dashboard.jellyfin`.

**Tech Stack:** Terraform, Grafana 13.1.3, Business Text 6.3.0, Grafana dashboard JSON schema 39, Prometheus/PromQL, HTML/CSS/JavaScript, Python `unittest`, Node.js, `jq`, authenticated in-app browser verification.

## Global Constraints

- Place p95 at `x=0, y=0, w=12, h=4` and p99 at `x=12, y=0, w=12, h=4`.
- Move every non-latency dashboard row down by four grid rows without changing its relative layout, size, query, or behavior.
- Preserve the exact p95/p99 PromQL expressions, `instant: true`, and `$__range` behavior.
- Preserve Business Text `6.3.0`; do not change Grafana, its plugin environment, HTML sanitization, or container configuration.
- Keep Good below 1 second, Needs improvement from 1 to below 2 seconds, and Poor at 2 seconds or above.
- Use a 0–3 second visual scale divided into three equal zones; highlight only the current zone green, orange, or red and render all other zones neutral.
- Keep the pointer neutral, move it independently of zone highlighting, and clamp values at or above 3 seconds to the right edge.
- Render neutral `No data` for missing/non-numeric results and reset pointer, quality label, status state, and all zone highlights.
- Preserve threshold-safe display truncation at the 1-second and 2-second boundaries.
- Expected tracked implementation changes are limited to `observability/jellyfin-dashboard.json.tftpl`, `observability/test_jellyfin_faro_cards.py`, and this plan.
- Preserve user-owned changes to `CLAUDE.md`, `.DS_Store`, `.codex/`, and `AGENTS.md`.
- Never apply a broad Terraform plan or a saved plan with any actionful resource other than an in-place update to `grafana_dashboard.jellyfin`.
- Do not replace or restart Grafana or any other container.

## File Structure

- Modify `observability/jellyfin-dashboard.json.tftpl`: update panels 4 and 9 markup, CSS, pointer mapping, and grid positions; reflow all other panels.
- Modify `observability/test_jellyfin_faro_cards.py`: execute and structurally verify zone selection, pointer mapping, compact first row, reflow, range behavior, reset behavior, and boundary-safe formatting.
- Create `.superpowers/sdd/2026-08-11-jellyfin-faro-meter-refinement/task-1-report.md`: ignored implementation and review evidence.
- Create `.superpowers/sdd/2026-08-11-jellyfin-faro-meter-refinement/task-2-report.md`: ignored deployment and live-verification evidence.

---

### Task 1: Implement the compact three-zone Faro meters

**Files:**
- Modify: `observability/test_jellyfin_faro_cards.py`
- Modify: `observability/jellyfin-dashboard.json.tftpl`
- Evidence: `.superpowers/sdd/2026-08-11-jellyfin-faro-meter-refinement/task-1-report.md`

**Interfaces:**
- Consumes: panels 4 and 9, raw numeric `context.data.Value` in seconds, and `run_after_render(script, values)`.
- Produces: top-row Business Text panels using `.jf-latency-zone--good`, `.jf-latency-zone--warning`, `.jf-latency-zone--poor`, neutral `.jf-latency-meter__pointer`, and `--latency-position` on a 0–3 second scale.

- [ ] **Step 1: Write failing executable behavior tests**

Change the expected position for `1.5` in `test_non_numeric_rerender_resets_imperative_card_state` from `30%` to `50%`.

In `test_threshold_adjacent_display_does_not_cross_quality_boundary`, preserve the current display/status assertions and assert the new positions numerically:

```python
self.assertAlmostEqual(
    float(states[0]["position"].removesuffix("%")), 33.32
)
self.assertAlmostEqual(
    float(states[1]["position"].removesuffix("%")), 66.63333333333333
)
```

Add this pointer-scale test:

```python
def test_latency_pointer_uses_zero_to_three_second_clamped_scale(self):
    for panel_id in (4, 9):
        with self.subTest(panel_id=panel_id):
            states = run_after_render(
                self.panels[panel_id]["options"]["afterRender"],
                [0, 1.5, 3, 4, None],
            )
            self.assertEqual(
                [state["position"] for state in states],
                ["0%", "50%", "100%", "100%", "0%"],
            )
            self.assertEqual(
                [state["quality"] for state in states],
                ["good", "warning", "poor", "poor", None],
            )
```

Replace the current meter-token test with:

```python
def test_latency_cards_use_three_exclusive_threshold_zones(self):
    required_content = (
        "jf-latency-zone--good",
        "jf-latency-zone--warning",
        "jf-latency-zone--poor",
        "jf-latency-meter__pointer",
        "jf-latency-tick--one",
        "jf-latency-tick--two",
    )
    required_styles = (
        ".jf-latency-meter__track {",
        "display: flex",
        ".jf-latency-zone {",
        "background: var(--neutral-zone)",
        "flex: 1 1 33.333333%",
        '[data-quality="good"] .jf-latency-zone--good { background: var(--good); }',
        '[data-quality="warning"] .jf-latency-zone--warning { background: var(--warning); }',
        '[data-quality="poor"] .jf-latency-zone--poor { background: var(--poor); }',
        "border-top: 7px solid var(--pointer)",
        ".jf-latency-tick--one { left: 33.333333%; }",
        ".jf-latency-tick--two { left: 66.666667%; }",
    )
    for panel_id in (4, 9):
        with self.subTest(panel_id=panel_id):
            options = self.panels[panel_id]["options"]
            for token in required_content:
                self.assertIn(token, options["content"])
                self.assertIn(token, options["defaultContent"])
            for token in required_styles:
                self.assertIn(token, options["styles"])
            self.assertNotIn("jf-latency-meter__fill", options["content"])
            self.assertIn(
                "Math.min(3, Math.max(0, seconds)) / 3 * 100",
                options["afterRender"],
            )
```

Because zone highlighting is selected exclusively by `root.dataset.quality`, retain the existing finite-to-null test that verifies `delete root.dataset.quality`; that transition is the executable proof that every zone returns to neutral for non-numeric data.

- [ ] **Step 2: Write the failing exact-layout test**

Replace `expected_grid` in `test_compact_grid_has_no_overlap` with:

```python
expected_grid = {
    4: {"h": 4, "w": 12, "x": 0, "y": 0},
    9: {"h": 4, "w": 12, "x": 12, "y": 0},
    1: {"h": 9, "w": 16, "x": 0, "y": 4},
    2: {"h": 9, "w": 8, "x": 16, "y": 4},
    8: {"h": 5, "w": 12, "x": 0, "y": 13},
    5: {"h": 5, "w": 3, "x": 0, "y": 18},
    10: {"h": 5, "w": 3, "x": 3, "y": 18},
    11: {"h": 5, "w": 3, "x": 6, "y": 18},
    12: {"h": 5, "w": 3, "x": 9, "y": 18},
    13: {"h": 5, "w": 3, "x": 12, "y": 18},
    14: {"h": 5, "w": 3, "x": 15, "y": 18},
    15: {"h": 5, "w": 3, "x": 18, "y": 18},
    16: {"h": 5, "w": 3, "x": 21, "y": 18},
    3: {"h": 8, "w": 24, "x": 0, "y": 23},
}
```

Retain the exhaustive pairwise non-overlap loop and all panel-count, plugin-safety, raw-number, exact-query, dashboard-range, reset, boundary-formatting, and template-interpolation tests.

- [ ] **Step 3: Run focused tests to establish RED**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_jellyfin_faro_cards
```

Expected: failures identify the old 0–5 second scale, progress-fill markup, 20%/40% threshold positions, and old panel grid. Record exact failures in `task-1-report.md`; stop if the new assertions pass before implementation.

- [ ] **Step 4: Implement the three-zone markup and dynamic highlighting**

Use this meter markup in both panel `content` and `defaultContent`; the default root additionally keeps `jf-latency-card--empty`:

```html
<div class="jf-latency-card">
  <div class="jf-latency-reading">
    <span class="jf-latency-value">No data</span>
    <span class="jf-latency-quality"></span>
  </div>
  <div class="jf-latency-meter">
    <span class="jf-latency-meter__pointer"></span>
    <div class="jf-latency-meter__track">
      <span class="jf-latency-zone jf-latency-zone--good"></span>
      <span class="jf-latency-zone jf-latency-zone--warning"></span>
      <span class="jf-latency-zone jf-latency-zone--poor"></span>
    </div>
    <span class="jf-latency-tick jf-latency-tick--one"><i></i><b>1 s</b></span>
    <span class="jf-latency-tick jf-latency-tick--two"><i></i><b>2 s</b></span>
  </div>
</div>
```

Preserve the current raw-number guard, non-finite reset, quality thresholds, labels, and threshold-safe truncation. Change only the pointer calculation to:

```javascript
const position = Math.min(3, Math.max(0, seconds)) / 3 * 100;
```

Continue escaping JavaScript template literals as `$${...}` in the Terraform template.

Use this panel-local CSS for both latency cards:

```css
.jf-latency-card { --good: rgb(115, 191, 105); --warning: rgb(255, 152, 48); --poor: rgb(242, 73, 92); --neutral-zone: rgba(204, 204, 220, 0.16); --pointer: rgb(204, 204, 220); --status-color: currentColor; --latency-position: 0%; box-sizing: border-box; display: flex; flex-direction: column; height: 100%; justify-content: flex-start; padding: 6px 8px 8px; }
.jf-latency-card[data-quality="good"] { --status-color: var(--good); }
.jf-latency-card[data-quality="warning"] { --status-color: var(--warning); }
.jf-latency-card[data-quality="poor"] { --status-color: var(--poor); }
.jf-latency-card[data-quality="good"] .jf-latency-zone--good { background: var(--good); }
.jf-latency-card[data-quality="warning"] .jf-latency-zone--warning { background: var(--warning); }
.jf-latency-card[data-quality="poor"] .jf-latency-zone--poor { background: var(--poor); }
.jf-latency-card--empty { opacity: 0.7; }
.jf-latency-reading { color: var(--status-color); font-size: 20px; font-weight: 600; line-height: 1.2; margin-bottom: 6px; white-space: nowrap; }
.jf-latency-quality { font-size: 13px; font-weight: 400; }
.jf-latency-meter { height: 34px; position: relative; }
.jf-latency-meter__track { display: flex; height: 8px; left: 0; overflow: hidden; position: absolute; right: 0; top: 7px; }
.jf-latency-zone { background: var(--neutral-zone); flex: 1 1 33.333333%; height: 100%; }
.jf-latency-meter__pointer { border-left: 5px solid transparent; border-right: 5px solid transparent; border-top: 7px solid var(--pointer); left: var(--latency-position); position: absolute; top: 0; transform: translateX(-50%); z-index: 1; }
.jf-latency-tick { color: currentColor; font-size: 11px; position: absolute; top: 7px; transform: translateX(-50%); }
.jf-latency-tick i { background: currentColor; display: block; height: 11px; margin: 0 auto 2px; opacity: 0.75; width: 1px; }
.jf-latency-tick b { font-weight: 400; white-space: nowrap; }
.jf-latency-tick--one { left: 33.333333%; }
.jf-latency-tick--two { left: 66.666667%; }
```

The neutral `.jf-latency-zone` rule is the default and no-data state. The three descendant selectors color exactly one zone based on the root's single `data-quality` value.

- [ ] **Step 5: Apply the exact grid reflow**

Set every panel `gridPos` to the dictionary from Step 2. Do not change any target, field configuration, option, title, or non-layout property outside panels 4 and 9.

- [ ] **Step 6: Run focused tests to establish GREEN**

Run:

```bash
PYTHONPATH=observability python3 -m unittest -v observability.test_jellyfin_faro_cards
```

Expected: all Faro tests pass, including exclusive zone selectors, neutral defaults, finite-to-null clearing, 0–3 second pointer clamping, exact grid, and pairwise non-overlap.

- [ ] **Step 7: Run full verification**

Run separately:

```bash
PYTHONPATH=observability python3 -m unittest discover -s observability -p 'test_*.py' -v
python3 -m py_compile observability/test_jellyfin_faro_cards.py
terraform fmt -check
terraform validate -no-color
git diff --check
```

Render the template with the same substitutions as `load_dashboard()` and require valid JSON. Remove only generated `observability/__pycache__`. Expected: all tests and checks pass; Terraform validation may emit only the existing Home Assistant development-override warning.

- [ ] **Step 8: Self-review and commit Task 1**

Verify the diff changes only the template and Faro tests, preserves exact PromQL and all range variables, and contains no external resource, unsafe HTML setting, fixed lookback, panel time override, or unrelated behavior change.

Commit:

```bash
git add observability/jellyfin-dashboard.json.tftpl observability/test_jellyfin_faro_cards.py
git commit -m "Refine Jellyfin Faro latency meters"
```

Record RED/GREEN evidence, final checks, commit SHA, and preserved user-owned status in `task-1-report.md`.

---

### Task 2: Deploy and visually verify the dashboard-only update

**Files:**
- No tracked repository changes
- Evidence: `.superpowers/sdd/2026-08-11-jellyfin-faro-meter-refinement/task-2-report.md`

**Interfaces:**
- Consumes: the reviewed Task 1 commit and current Terraform state.
- Produces: a deployed, authenticated, converged Jellyfin dashboard with no container replacement or tracked deployment edits.

- [ ] **Step 1: Establish preflight and dependency literals**

Record `git status --short`, `git diff --check`, `terraform fmt -check`, `terraform validate -no-color`, and focused Faro tests. Require no Terraform lock, no `observability/__pycache__`, and no diff in `observability.tf`.

Read Terraform state and require the current dependency values to be folder UID `afu9hvo3v3g8wa` and Prometheus datasource UID `prometheus`. Stop rather than guessing if either differs.

- [ ] **Step 2: Create and gate an isolated saved plan**

Use `apply_patch` to temporarily replace only the two expressions in `grafana_dashboard.jellyfin`:

```hcl
folder = "afu9hvo3v3g8wa"
```

```hcl
datasource_uid = "prometheus"
```

Run:

```bash
terraform plan -target=grafana_dashboard.jellyfin -out=/tmp/jellyfin-faro-meter-refinement.tfplan
terraform show -json /tmp/jellyfin-faro-meter-refinement.tfplan > /tmp/jellyfin-faro-meter-refinement.tfplan.json
jq -e '[.resource_changes[] | select(.change.actions != ["no-op"]) | {address, actions: .change.actions}] == [{"address":"grafana_dashboard.jellyfin","actions":["update"]}]' /tmp/jellyfin-faro-meter-refinement.tfplan.json
```

Expected: the gate returns `true`. Inspect the human-readable plan and require only the reviewed geometry, markup, CSS, and pointer-scale change. Stop on any provider, container, plugin, query, or unrelated dashboard change.

- [ ] **Step 3: Restore committed Terraform before apply**

Use `apply_patch` to restore `grafana_folder.homelab.uid` and `grafana_data_source.prometheus.uid`. Run `terraform fmt -check`, `git diff --exit-code -- observability.tf`, `git diff --check`, and verify no Terraform lock. Stop unless `observability.tf` is exact.

- [ ] **Step 4: Apply only the gated saved plan**

Run:

```bash
terraform apply -no-color /tmp/jellyfin-faro-meter-refinement.tfplan
```

Expected: `0 added, 1 changed, 0 destroyed`, modifying only `grafana_dashboard.jellyfin`. Run no other apply.

- [ ] **Step 5: Verify deployed state**

Export current Terraform state as JSON and assert both latency panels have the exact grids, unchanged queries, `instant: true`, no time override, all three zone classes, neutral zone defaults, three exclusive quality selectors, neutral pointer, one-third/two-thirds ticks, 0–3 second clamping, non-finite reset, and threshold-safe truncation. Require fourteen panels and the exact non-overlapping Task 1 grid.

- [ ] **Step 6: Verify authenticated rendering at 24 hours, 1 hour, and 5 minutes**

In the authenticated in-app browser, confirm at each range:

- p95 and p99 occupy the equal half-width compact first row;
- value/unit/quality is left-aligned above the meter;
- exactly the current value's zone is highlighted: green, orange, or red;
- the other zones are neutral and the neutral triangle independently marks the value;
- `1 s` and `2 s` sit at one third and two thirds;
- all other panels reflow without overlap and refresh with the selected range;
- the console has no Business Text, JavaScript, React, template, or datasource errors.

Capture a full 24-hour screenshot and focused 1-hour and 5-minute card screenshots. For genuine no-data ranges, require all zones neutral, pointer at the left edge, visible threshold guide, and no false `0 ms (Good)`; never alter queries or fabricate data.

- [ ] **Step 7: Prove convergence without applying it**

Repeat only the two temporary dependency cuts, save `/tmp/jellyfin-faro-meter-refinement-converged.tfplan`, export its JSON, and restore `observability.tf` before interpreting the result. Require:

```bash
jq -e '[.resource_changes[] | select(.change.actions != ["no-op"])] == []' /tmp/jellyfin-faro-meter-refinement-converged.tfplan.json
```

Expected: Terraform reports no changes and the gate returns `true`. Never apply this convergence plan.

- [ ] **Step 8: Run final repository gates**

Run the full observability suite, focused Faro tests, `py_compile`, rendered-template JSON parsing, `terraform fmt -check`, `terraform validate -no-color`, and `git diff --check`. Require no `observability.tf` diff, Terraform lock, or `observability/__pycache__`, and preserve the pre-existing user-owned status. Record plan/apply/state/browser/convergence/test evidence in `task-2-report.md`; make no deployment commit.
