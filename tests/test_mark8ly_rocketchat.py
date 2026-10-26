import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_onboarding_uses_server_only_openbao_bot_credentials():
    rendered = subprocess.check_output([
        "helm", "template", "mark8ly-platform-api",
        str(ROOT / "charts/apps/mark8ly-platform-api"),
    ], text=True)
    docs = list(yaml.safe_load_all(rendered))
    deployment = next(d for d in docs if d and d["kind"] == "Deployment")
    env = {e["name"]: e for e in deployment["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["ROCKETCHAT_ONBOARDING_ENABLED"]["value"] == "true"
    assert env["ROCKETCHAT_URL"]["value"] == "https://rocketchat.tesserix.app"
    for key in ("ROCKETCHAT_AUTH_TOKEN", "ROCKETCHAT_USER_ID", "ROCKETCHAT_ONBOARDING_ROOM_ID"):
        assert env[key]["valueFrom"]["secretKeyRef"] == {
            "name": "mark8ly-rocketchat-onboarding", "key": key,
        }
    secret = yaml.safe_load((ROOT / "external-secrets/prod/mark8ly/rocketchat.yaml").read_text())
    assert secret["spec"]["secretStoreRef"] == {"name": "openbao-mark8ly-production", "kind": "SecretStore"}
    assert {d["secretKey"] for d in secret["spec"]["data"]} == {
        "ROCKETCHAT_AUTH_TOKEN", "ROCKETCHAT_USER_ID", "ROCKETCHAT_ONBOARDING_ROOM_ID",
    }
    assert all(d["remoteRef"]["key"] == "mark8ly/app/mark8ly-rocketchat-onboarding" for d in secret["spec"]["data"])
    resources = yaml.safe_load((ROOT / "external-secrets/prod/mark8ly/kustomization.yaml").read_text())["resources"]
    assert "rocketchat.yaml" in resources
    text = (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
    assert 'path "kv/data/mark8ly/app/mark8ly-rocketchat-onboarding" { capabilities = ["read"] }' in text
