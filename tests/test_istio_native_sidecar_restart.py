import copy
import json
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
KEY = "resource.customizations.ignoreDifferences.apps_Deployment"
TIMESTAMP = "kubectl.kubernetes.io/restartedAt"


class NativeSidecarRestartTests(unittest.TestCase):
    def test_restart_ignore_is_limited_to_helivanta_timestamp(self):
        instance = yaml.safe_load(
            (ROOT / "charts/argocd-operator/argocd-instance.yaml").read_text()
        )
        override = yaml.safe_load(instance["spec"]["extraConfig"][KEY])
        self.assertEqual(len(override["jqPathExpressions"]), 1)
        expression = override["jqPathExpressions"][0]
        for namespace in ("helivanta", "other-product"):
            original = {
                "metadata": {"namespace": namespace},
                "spec": {
                    "template": {
                        "metadata": {
                            "annotations": {
                                TIMESTAMP: "2026-11-10T03:00:00Z",
                                "proxy.istio.io/config": "preserve",
                            }
                        },
                        "spec": {
                            "containers": [
                                {"name": "api", "image": "application:unchanged"}
                            ]
                        },
                    }
                },
            }
            expected = copy.deepcopy(original)
            if namespace == "helivanta":
                del expected["spec"]["template"]["metadata"]["annotations"][TIMESTAMP]
            normalized = json.loads(
                subprocess.check_output(
                    ["jq", f"del({expression})"], input=json.dumps(original), text=True
                )
            )
            self.assertEqual(normalized, expected)


if __name__ == "__main__":
    unittest.main()
