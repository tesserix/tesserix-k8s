import json
from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).parents[1]


def render(chart, *arguments):
    result = subprocess.run(
        ["helm", "template", "helivanta-growthbook", str(ROOT / chart), *arguments],
        check=True, capture_output=True, text=True,
    )
    return [row for row in yaml.safe_load_all(result.stdout) if row]


def test_api_only_mode_keeps_provider_and_database():
    rows = render("charts/thirdparty/growthbook", "--set", "fullnameOverride=helivanta-growthbook",
                  "--set", "helivantaDedicated.enabled=true", "--set", "helivantaRelease.enabled=true",
                  "--set", "helivantaRelease.consoleManaged=true", "--set", "apiOnly=true")
    deployment = next(row for row in rows if row["kind"] == "Deployment" and row["metadata"]["name"] == "helivanta-growthbook")
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert container["command"] == ["node", "scripts/run-apps.js"]
    assert container["args"] == ["start", "ecosystem.config.js", "--only", "back-end"]
    assert [port["name"] for port in container["ports"]] == ["api"]
    assert container["readinessProbe"]["httpGet"]["port"] == "api"
    assert any(row["kind"] == "Deployment" and row["metadata"]["name"].endswith("-mongodb") for row in rows)
    config = next(row for row in rows if row["kind"] == "ConfigMap" and row["metadata"]["name"] == "growthbook-helivanta-release")
    assert json.loads(config["data"]["helivanta-release.json"])["consoleManaged"] is True
    assert "helivanta-management.mjs" in config["data"]


def test_live_intent_keeps_ui_until_acceptance_and_mounts_separate_credentials():
    app = yaml.safe_load((ROOT / "argocd/prod/apps/helivanta/helivanta-growthbook.yaml").read_text())
    values = yaml.safe_load(app["spec"]["source"]["helm"]["values"])
    assert values["helivantaRelease"]["consoleManaged"] is True
    assert values.get("apiOnly", False) is False
    values = yaml.safe_load((ROOT / "charts/apps/platform-api/values-prod.yaml").read_text())
    assert values["featureFlags"] == {"enabled": True, "secretName": "platform-api-helivanta-growthbook"}
    secrets = list(yaml.safe_load_all((ROOT / "external-secrets/prod/tesserix/externalsecret.yaml").read_text()))
    secret = next(row for row in secrets if row and row["metadata"]["name"] == "platform-api-helivanta-growthbook")
    assert secret["spec"]["secretStoreRef"]["name"] == "openbao-platform-api-production"
    assert {row["remoteRef"]["key"] for row in secret["spec"]["data"]} == {"helivanta/prod/app/helivanta-growthbook-management"}
    policies = yaml.safe_load((ROOT / "charts/thirdparty/openbao/values.yaml").read_text())["bootstrap"]["policies"]
    reader = next(row for row in policies if row["name"] == "read-platform-api-tesserix-production")
    assert 'path "kv/data/helivanta/prod/app/helivanta-growthbook-management" { capabilities = ["read"] }' in reader["hcl"]
