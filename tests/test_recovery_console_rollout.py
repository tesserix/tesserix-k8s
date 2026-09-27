from pathlib import Path
import subprocess

import yaml


def test_console_api_receives_only_the_recovery_catalog_bucket():
    root = Path(__file__).resolve().parents[1]
    rendered = subprocess.check_output(
        [
            "helm",
            "template",
            "secret-service",
            str(root / "charts/apps/secret-service"),
        ],
        text=True,
    )
    deployment = next(
        doc
        for doc in yaml.safe_load_all(rendered)
        if doc and doc["kind"] == "Deployment"
    )
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    env = {entry["name"]: entry.get("value") for entry in container["env"]}
    assert env["OPENBAO_RECOVERY_BUCKET"] == "tesseracthub-480811-openbao-recovery-prod"
    assert not any("TOKEN" in key and value for key, value in env.items())
