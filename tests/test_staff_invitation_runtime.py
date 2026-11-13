import pathlib
import subprocess
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


class StaffInvitationRuntime(unittest.TestCase):
    def environment(self, production):
        chart = ROOT / "charts/apps/onboarding-service"
        args = ["helm", "template", "onboarding-service", str(chart)]
        if production:
            args += ["-f", str(chart / "values-prod.yaml")]
        else:
            args += ["--set", "console.accessProjectId=test-project", "--set", "console.accessClientId=test-client"]
        docs = list(yaml.safe_load_all(subprocess.check_output(args, text=True)))
        deployment = next(d for d in docs if d and d["kind"] == "Deployment")
        return deployment["spec"]["template"]["spec"]["containers"][0]["env"]

    def test_production_enables_only_the_registered_helivanta_product(self):
        entries = [v for v in self.environment(True) if v["name"] == "STAFF_IDENTITY_PRODUCT_KEY"]
        self.assertEqual(entries, [{"name": "STAFF_IDENTITY_PRODUCT_KEY", "value": "helivanta"}])

    def test_default_chart_does_not_enable_staff_provisioning(self):
        self.assertFalse(any(v["name"] == "STAFF_IDENTITY_PRODUCT_KEY" for v in self.environment(False)))
