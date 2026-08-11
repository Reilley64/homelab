import json
import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OBSERVABILITY_TF = ROOT / "observability.tf"
DASHBOARD_TEMPLATE = ROOT / "observability" / "jellyfin-dashboard.json.tftpl"
PLUGIN_ENV = "GF_PLUGINS_PREINSTALL=marcusolsson-dynamictext-panel@6.3.0"


def load_dashboard():
    rendered = DASHBOARD_TEMPLATE.read_text().replace("$${", "${").replace(
        "${datasource_uid}", "test-prometheus"
    )
    return json.loads(rendered)


def run_after_render(script, values):
    harness = r"""
const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const valueElement = { textContent: 'No data' };
const qualityElement = { textContent: '' };
const properties = {};
const root = {
  dataset: {},
  style: { setProperty: (name, value) => { properties[name] = value; } },
  querySelector: (selector) => selector === '.jf-latency-value' ? valueElement : qualityElement,
};
const context = {
  element: { querySelector: () => root },
  data: {},
};
const afterRender = new Function('context', input.script);
const states = input.values.map((value) => {
  context.data.Value = value;
  afterRender(context);
  return {
    quality: root.dataset.quality ?? null,
    position: properties['--latency-position'] ?? null,
    valueText: valueElement.textContent,
    qualityText: qualityElement.textContent,
  };
});
process.stdout.write(JSON.stringify(states));
"""
    completed = subprocess.run(
        ["node", "-e", harness],
        input=json.dumps({"script": script, "values": values}),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(completed.stdout)


class GrafanaPluginConfigurationTests(unittest.TestCase):
    def test_business_text_is_pinned_once(self):
        source = OBSERVABILITY_TF.read_text()
        self.assertEqual(source.count(PLUGIN_ENV), 1)

    def test_unsafe_html_and_unsigned_plugins_remain_disabled(self):
        source = OBSERVABILITY_TF.read_text()
        self.assertNotIn("GF_PANELS_DISABLE_SANITIZE_HTML", source)
        self.assertNotIn("GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS", source)


class FaroLatencyDashboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboard = load_dashboard()
        cls.panels = {panel["id"]: panel for panel in cls.dashboard["panels"]}

    def test_dashboard_keeps_exactly_the_six_useful_panels(self):
        ids = [panel["id"] for panel in self.dashboard["panels"]]
        self.assertEqual(ids, [1, 2, 8, 4, 9, 3])
        self.assertEqual(len(ids), 6)
        self.assertEqual(len(set(ids)), 6)

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

    def test_latency_panels_leave_values_raw_for_custom_formatting(self):
        for panel_id in (4, 9):
            with self.subTest(panel_id=panel_id):
                self.assertEqual(
                    self.panels[panel_id]["fieldConfig"],
                    {"defaults": {}, "overrides": []},
                )

    def test_non_numeric_rerender_resets_imperative_card_state(self):
        expected = [
            {
                "quality": "warning",
                "position": "50%",
                "valueText": "1.50 s",
                "qualityText": "(Needs improvement)",
            },
            {
                "quality": None,
                "position": "0%",
                "valueText": "No data",
                "qualityText": "",
            },
        ]
        for panel_id in (4, 9):
            with self.subTest(panel_id=panel_id):
                states = run_after_render(
                    self.panels[panel_id]["options"]["afterRender"], [1.5, None]
                )
                self.assertEqual(states, expected)

    def test_default_content_contains_every_non_numeric_reset_target(self):
        for panel_id in (4, 9):
            with self.subTest(panel_id=panel_id):
                default_content = self.panels[panel_id]["options"]["defaultContent"]
                self.assertIn("jf-latency-value", default_content)
                self.assertIn("jf-latency-quality", default_content)

    def test_latency_quality_has_a_visible_gap_from_the_value(self):
        for panel_id in (4, 9):
            with self.subTest(panel_id=panel_id):
                self.assertIn(
                    ".jf-latency-quality { font-size: 13px; font-weight: 400; margin-left: 0.25em; }",
                    self.panels[panel_id]["options"]["styles"],
                )

    def test_threshold_adjacent_display_does_not_cross_quality_boundary(self):
        expected = [
            {
                "quality": "good",
                "valueText": "999 ms",
                "qualityText": "(Good)",
            },
            {
                "quality": "warning",
                "valueText": "1.99 s",
                "qualityText": "(Needs improvement)",
            },
        ]
        for panel_id in (4, 9):
            with self.subTest(panel_id=panel_id):
                states = run_after_render(
                    self.panels[panel_id]["options"]["afterRender"],
                    [0.9996, 1.999],
                )
                for state, expected_state in zip(states, expected):
                    self.assertEqual(
                        {key: state[key] for key in expected_state}, expected_state
                    )
                self.assertAlmostEqual(
                    float(states[0]["position"].removesuffix("%")), 33.32
                )
                self.assertAlmostEqual(
                    float(states[1]["position"].removesuffix("%")), 66.63333333333333
                )

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

    def test_template_escapes_javascript_interpolations_and_preserves_them_rendered(self):
        source = DASHBOARD_TEMPLATE.read_text()
        raw_interpolations = re.findall(r"(?<!\$)\$\{([^}]+)\}", source)
        self.assertGreater(len(raw_interpolations), 0)
        self.assertTrue(all(expression == "datasource_uid" for expression in raw_interpolations))

        rendered = source.replace("$${", "${").replace(
            "${datasource_uid}", "test-prometheus"
        )
        dashboard = json.loads(rendered)
        expected_literals = (
            "${Math.trunc(seconds * 1000)} ms",
            "${truncatedSeconds.toFixed(decimals)} s",
            "${position}%",
            "(${label})",
        )
        for panel in dashboard["panels"]:
            if panel["id"] in (4, 9):
                with self.subTest(panel_id=panel["id"]):
                    for literal in expected_literals:
                        self.assertIn(literal, panel["options"]["afterRender"])

    def test_compact_grid_has_no_overlap(self):
        expected_grid = {
            4: {"h": 4, "w": 12, "x": 0, "y": 0},
            9: {"h": 4, "w": 12, "x": 12, "y": 0},
            2: {"h": 6, "w": 6, "x": 0, "y": 4},
            8: {"h": 6, "w": 18, "x": 6, "y": 4},
            1: {"h": 10, "w": 24, "x": 0, "y": 10},
            3: {"h": 10, "w": 24, "x": 0, "y": 20},
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


if __name__ == "__main__":
    unittest.main()
