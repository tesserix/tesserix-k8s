import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).parents[1]


def test_both_api_workloads_default_to_openbao_with_a_valid_app_namespace():
    for role in ("admin", "storefront"):
        name = "mark8ly-marketplace-api-" + role
        docs = yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    name,
                    str(ROOT / "charts/apps" / name),
                    "--namespace",
                    "mark8ly",
                ],
                text=True,
            )
        )
        deployment = next(d for d in docs if d and d["kind"] == "Deployment")
        env = {
            e["name"]: e.get("value")
            for e in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        assert env["SHIPPING_SECRET_STORE"] == "bao"
        assert env["APPCREDS_PROJECT_ID"] == "mark8ly"
        assert env["OPENBAO_ROLE"] == name
