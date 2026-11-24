import json
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).parents[1]


class CatalogueChartTests(unittest.TestCase):
    def render(self, chart, *args):
        result = subprocess.run(
            ["helm", "template", "test", str(ROOT / chart), *args],
            check=True,
            capture_output=True,
            text=True,
        )
        return list(yaml.safe_load_all(result.stdout))

    def test_staff_authenticator_recovery_publishes_reviewed_release_dependencies(self):
        objects = self.render(
            "charts/apps/onboarding-service",
            "-f",
            str(ROOT / "charts/apps/onboarding-service/values-prod.yaml"),
        )
        config = next(
            row
            for row in objects
            if row
            and row["kind"] == "ConfigMap"
            and row["metadata"]["name"] == "helivanta-feature-catalogue"
        )
        catalogue = json.loads(config["data"]["catalogue.json"])
        definitions = {row["key"]: row for row in catalogue["capabilities"]}
        self.assertEqual(
            definitions.get("staff_mfa_recovery"),
            {
                "key": "staff_mfa_recovery",
                "owner": "workforce",
                "eligible": True,
                "dependencies": ["staff_core", "team_accounts"],
            },
        )

    def test_pharmacy_release_preserves_narrow_dependencies_and_broad_locks(self):
        objects = self.render(
            "charts/apps/onboarding-service",
            "-f",
            str(ROOT / "charts/apps/onboarding-service/values-prod.yaml"),
        )
        config = next(
            row for row in objects if row and row["kind"] == "ConfigMap"
            and row["metadata"]["name"] == "helivanta-feature-catalogue"
        )
        catalogue = json.loads(config["data"]["catalogue.json"])
        definitions = {row["key"]: row for row in catalogue["capabilities"]}
        self.assertEqual(catalogue["policy_version"], "2026-11-24.pharmacy-low-stock.v1")
        self.assertEqual(definitions.get("pharmacy_stocktake"), {
            "key": "pharmacy_stocktake", "owner": "pharmacy", "eligible": True,
            "dependencies": ["pharmacy_setup"],
        })
        self.assertEqual(definitions.get("pharmacy_low_stock"), {
            "key": "pharmacy_low_stock", "owner": "pharmacy", "eligible": False,
            "dependencies": ["pharmacy_setup"],
        })
        self.assertEqual(definitions["pharmacy_stock"]["dependencies"], [
            "pharmacy_catalogue", "pharmacy_low_stock",
        ])
        for key in ("pharmacy_catalogue", "pharmacy_stock", "pharmacy_counter", "pharmacy_payables", "supplier_collaboration"):
            self.assertFalse(definitions[key]["eligible"], key)


    def test_onboarding_publishes_catalogue_and_same_runtime_schema(self):
        objects = self.render(
            "charts/apps/onboarding-service",
            "-f",
            str(ROOT / "charts/apps/onboarding-service/values-prod.yaml"),
        )
        config = next(
            row
            for row in objects
            if row
            and row["kind"] == "ConfigMap"
            and row["metadata"]["name"] == "helivanta-feature-catalogue"
        )
        self.assertEqual(config["metadata"]["namespace"], "helivanta-growthbook")
        schema = json.loads(config["data"]["schema.json"])
        self.assertEqual(
            schema,
            json.loads(
                (
                    ROOT
                    / "charts/apps/onboarding-service/files/helivanta-catalogue.schema.json"
                ).read_text()
            ),
        )
        catalogue = json.loads(config["data"]["catalogue.json"])
        self.assertGreater(len(catalogue["capabilities"]), 0)
        for bad in ({**catalogue, "unknown": True}, {**catalogue, "capabilities": []}):
            result = subprocess.run(
                [
                    "helm",
                    "template",
                    "test",
                    str(ROOT / "charts/apps/onboarding-service"),
                    "-f",
                    str(ROOT / "charts/apps/onboarding-service/values-prod.yaml"),
                    "--set-json",
                    "helivantaFeatureCatalogue.catalogue=" + json.dumps(bad),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)

    def test_reconciler_has_no_api_token_and_uses_provider_pin(self):
        objects = self.render(
            "charts/thirdparty/growthbook",
            "--set",
            "helivantaDedicated.enabled=true",
            "--set",
            "helivantaRelease.enabled=true",
            "--set",
            "helivantaRelease.consoleManaged=true",
            "--set",
            "helivantaCatalogue.enabled=true",
            "--set",
            "apiOnly=true",
        )
        job = next(row for row in objects if row and row["kind"] == "CronJob")
        self.assertEqual(job["spec"]["concurrencyPolicy"], "Forbid")
        spec = job["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        self.assertFalse(spec["automountServiceAccountToken"])
        self.assertNotIn("serviceAccountToken", json.dumps(spec["volumes"]))
        self.assertIn("@sha256:", spec["containers"][0]["image"])
        self.assertEqual(
            spec["containers"][0]["command"],
            ["node", "/config/helivanta-catalogue.mjs", "--run"],
        )
        self.assertTrue(
            all(row["readOnly"] for row in spec["containers"][0]["volumeMounts"])
        )


if __name__ == "__main__":
    unittest.main()


def test_activation_intent_enables_only_the_dedicated_catalogue_reconciler():
    app = yaml.safe_load(
        (ROOT / "argocd/prod/apps/helivanta/helivanta-growthbook.yaml").read_text()
    )
    values = yaml.safe_load(app["spec"]["source"]["helm"]["values"])
    assert values.get("helivantaCatalogue", {}).get("enabled") is True
    assert values["helivantaDedicated"]["enabled"] is True
    assert values["helivantaRelease"]["consoleManaged"] is True
    assert values["apiOnly"] is True
