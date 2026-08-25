import json
from pathlib import Path
import subprocess
import unittest


REPO = Path(__file__).resolve().parents[2]
FIXTURE = "tests/observability/fixtures/public-services.json"


def terraform_json(expression: str):
    result = subprocess.run(
        ["terraform", "console"],
        cwd=REPO,
        input=f"jsonencode({expression})\n",
        capture_output=True,
        text=True,
        check=True,
    )
    encoded = json.loads(result.stdout.strip().splitlines()[-1])
    return json.loads(encoded)


class ProbeConfigurationTest(unittest.TestCase):
    def test_blackbox_https_module(self):
        config = terraform_json(
            'yamldecode(file("observability/blackbox.yml"))'
        )
        module = config["modules"]["https_2xx"]

        self.assertEqual(module["prober"], "http")
        self.assertEqual(module["timeout"], "10s")
        self.assertEqual(module["http"]["valid_status_codes"], [])
        self.assertTrue(module["http"]["follow_redirects"])
        self.assertTrue(module["http"]["fail_if_not_ssl"])
        self.assertEqual(module["http"]["preferred_ip_protocol"], "ip4")

    def test_prometheus_keeps_existing_jobs_and_adds_all_probes(self):
        config = terraform_json(
            'yamldecode(templatefile("observability/prometheus.yml.tftpl", {'
            f' public_services = jsondecode(file("{FIXTURE}")).services '
            '}))'
        )
        jobs = {job["job_name"]: job for job in config["scrape_configs"]}

        self.assertTrue(
            {"traefik", "node", "jellyfin-egress", "prometheus"}
            <= set(jobs)
        )
        self.assertEqual(jobs["blackbox"]["scrape_interval"], "60s")
        self.assertEqual(jobs["blackbox"]["scrape_timeout"], "15s")
        self.assertEqual(jobs["blackbox"]["params"]["module"], ["https_2xx"])
        self.assertEqual(
            jobs["blackbox-exporter"]["static_configs"][0]["targets"],
            ["blackbox-exporter:9115"],
        )

        checks = {
            config["labels"]["service"]: (
                config["labels"]["service_name"],
                config["targets"][0],
            )
            for config in jobs["blackbox"]["static_configs"]
        }
        fixture = json.loads((REPO / FIXTURE).read_text())["services"]
        expected = {
            key: (service["display_name"], service["url"])
            for key, service in fixture.items()
        }
        self.assertEqual(checks, expected)

        relabeling = jobs["blackbox"]["relabel_configs"]
        self.assertEqual(relabeling[0]["target_label"], "__param_target")
        self.assertEqual(relabeling[1]["target_label"], "instance")
        self.assertEqual(relabeling[2]["replacement"], "blackbox-exporter:9115")


if __name__ == "__main__":
    unittest.main()
