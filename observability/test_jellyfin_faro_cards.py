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
                "position": "30%",
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

    def test_threshold_adjacent_display_does_not_cross_quality_boundary(self):
        expected = [
            {
                "quality": "good",
                "position": "19.992%",
                "valueText": "999 ms",
                "qualityText": "(Good)",
            },
            {
                "quality": "warning",
                "position": "39.980000000000004%",
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
                self.assertEqual(states, expected)

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


if __name__ == "__main__":
    unittest.main()
