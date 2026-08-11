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
