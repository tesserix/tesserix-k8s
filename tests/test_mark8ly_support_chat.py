"""Support delivery stays server-side and scoped to one product's credential."""
from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(*args):
    result = subprocess.run(["helm", "template", "support-platform-otto", str(ROOT / "charts/apps/support-platform-otto"), *args], check=True, capture_output=True, text=True)
    return list(yaml.safe_load_all(result.stdout))


def test_bot_credentials_only_when_enabled():
    for enabled in (False, True):
        docs = render("--set", f"rocketchat.enabled={str(enabled).lower()}")
        deployment = next(d for d in docs if d and d["kind"] == "Deployment")
        env = {v["name"]: v for v in deployment["spec"]["template"]["spec"]["containers"][0]["env"]}
        assert env["ROCKETCHAT_SUPPORT_ENABLED"]["value"] == str(enabled).lower()
        if enabled:
            for key in ("ROCKETCHAT_SUPPORT_AUTH_TOKEN", "ROCKETCHAT_SUPPORT_USER_ID", "ROCKETCHAT_SUPPORT_ROOM_ID"):
                assert env[key]["valueFrom"]["secretKeyRef"] == {"name": "mark8ly-rocketchat-support", "key": key}
        else:
            assert "ROCKETCHAT_SUPPORT_AUTH_TOKEN" not in env


def test_support_bot_uses_exact_openbao_path():
    secret = yaml.safe_load((ROOT / "external-secrets/prod/support-platform/rocketchat.yaml").read_text())
    assert secret["metadata"]["namespace"] == "support-platform"
    assert secret["spec"]["secretStoreRef"] == {"name": "openbao-support-platform-production", "kind": "SecretStore"}
    assert {d["remoteRef"]["key"] for d in secret["spec"]["data"]} == {"support-platform/app/support-platform-mark8ly-rocketchat"}
    assert {d["remoteRef"]["property"] for d in secret["spec"]["data"]} == {"token", "user_id", "room_id"}
