import subprocess
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]


class HelivantaApiStartupTests(unittest.TestCase):
    def test_authorization_bootstrap_has_a_bounded_startup_window(self):
        documents = yaml.safe_load_all(subprocess.check_output(
            ["helm", "template", "helivanta-api", str(ROOT / "charts/apps/helivanta-api"),
             "--namespace", "helivanta"], text=True))
        deployment = next(item for item in documents if item and item["kind"] == "Deployment")
        api = next(item for item in deployment["spec"]["template"]["spec"]["containers"]
                   if item["name"] == "api")
        startup = api["startupProbe"]
        self.assertEqual({"path": "/healthz", "port": "http"}, startup["httpGet"])
        self.assertEqual(180, startup["periodSeconds"] * startup["failureThreshold"])
        self.assertEqual(1, startup["timeoutSeconds"])
        self.assertEqual("/healthz", api["livenessProbe"]["httpGet"]["path"])
        self.assertEqual(5, api["livenessProbe"]["initialDelaySeconds"])
        self.assertEqual(10, api["livenessProbe"]["periodSeconds"])
        self.assertEqual(3, api["livenessProbe"]["failureThreshold"])
        self.assertEqual("/readyz", api["readinessProbe"]["httpGet"]["path"])
        self.assertEqual(3, api["readinessProbe"]["initialDelaySeconds"])
        self.assertEqual(3, api["readinessProbe"]["periodSeconds"])
        self.assertEqual(2, api["readinessProbe"]["failureThreshold"])


if __name__ == "__main__":
    unittest.main()
