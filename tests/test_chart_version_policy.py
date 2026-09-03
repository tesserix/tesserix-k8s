import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/chart_version_policy.py"
SPEC = importlib.util.spec_from_file_location("chart_version_policy", SCRIPT)
assert SPEC and SPEC.loader
chart_version_policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(chart_version_policy)


class ChartVersionPolicyTest(unittest.TestCase):
    def test_values_only_changes_do_not_require_chart_version_increment(self):
        self.assertFalse(
            chart_version_policy.requires_version_increment(
                [
                    "charts/apps/obs-api/values.yaml",
                    "charts/apps/obs-ui/values-prod.yaml",
                ]
            )
        )

    def test_template_change_requires_chart_version_increment(self):
        self.assertTrue(
            chart_version_policy.requires_version_increment(
                ["charts/apps/obs-ui/templates/deployment.yaml"]
            )
        )

    def test_chart_metadata_change_requires_chart_version_increment(self):
        self.assertTrue(
            chart_version_policy.requires_version_increment(
                ["charts/apps/obs-ui/Chart.yaml"]
            )
        )

    def test_unrelated_changes_do_not_require_chart_version_increment(self):
        self.assertFalse(
            chart_version_policy.requires_version_increment(["docs/runbook.md"])
        )


if __name__ == "__main__":
    unittest.main()
