import json
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
TENANT = "018f8f5b-1111-7111-8111-111111111111"


def render(extra=None):
    args = ["helm", "template", "helivanta-api", "charts/apps/helivanta-api", "--namespace", "helivanta"]
    for setting in extra or []:
        args += ["--set", setting]
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True)


def test_pilot_is_absent_unless_explicitly_configured():
    result = render()
    assert result.returncode == 0, result.stderr
    assert "RELEASE_PILOT_POLICY_FILE" not in result.stdout
    assert "release-pilot-policy" not in result.stdout


def test_pilot_mounts_only_a_readonly_policy_and_restarts_on_policy_change():
    result = render(["releaseCapabilities.enabled=true", "releaseCapabilities.pilot.enabled=true", f"releaseCapabilities.pilot.tenantIDs[0]={TENANT}", "releaseCapabilities.pilot.expiresAt=2026-11-26T00:00:00Z"])
    assert result.returncode == 0, result.stderr
    rows = [r for r in yaml.safe_load_all(result.stdout) if r]
    config = next(r for r in rows if r["kind"] == "ConfigMap" and r["metadata"]["name"] == "helivanta-api-release-pilot-policy")
    assert json.loads(config["data"]["policy.json"]) == {"tenant_ids": [TENANT], "expires_at": "2026-11-26T00:00:00Z"}
    deployment = next(r for r in rows if r["kind"] == "Deployment")
    pod = deployment["spec"]["template"]
    assert pod["metadata"]["annotations"]["checksum/release-pilot-policy"]
    api = next(r for r in pod["spec"]["containers"] if r["name"] == "api")
    assert {r["name"]: r["value"] for r in api["env"] if r["name"] == "RELEASE_PILOT_POLICY_FILE"} == {"RELEASE_PILOT_POLICY_FILE": "/var/run/release-pilot/policy.json"}
    assert next(r for r in api["volumeMounts"] if r["name"] == "release-pilot-policy")["readOnly"] is True


def test_pilot_requires_provider_tenants_and_expiry():
    for extra in [
        ["releaseCapabilities.pilot.enabled=true"],
        ["releaseCapabilities.enabled=true", "releaseCapabilities.pilot.enabled=true"],
        ["releaseCapabilities.enabled=true", "releaseCapabilities.pilot.enabled=true", f"releaseCapabilities.pilot.tenantIDs[0]={TENANT}"],
    ]:
        assert render(extra).returncode != 0
