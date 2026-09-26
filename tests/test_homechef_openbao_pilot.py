import pathlib
import shutil
import subprocess

import pytest
import yaml

ROOT = pathlib.Path(__file__).parents[1]


@pytest.fixture
def chart(tmp_path):
    shutil.copytree(ROOT / "charts/apps/homechef-api", tmp_path / "homechef-api")
    shutil.copytree(
        ROOT / "charts/apps/common", tmp_path / "homechef-api/charts/common"
    )
    return tmp_path / "homechef-api"


def render(chart, enabled):
    result = subprocess.run(
        [
            "helm",
            "template",
            "homechef-api",
            str(chart),
            "--namespace",
            "homechef",
            "-f",
            str(chart / "values-prod.yaml"),
            "--set",
            f"openbao.exchangeRatePilot.enabled={str(enabled).lower()}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def test_pilot_changes_only_one_remote_source_and_preserves_consumers(chart):
    baseline = render(chart, False)
    pilot = render(chart, True)
    baseline_secret = next(d for d in baseline if d["kind"] == "ExternalSecret")
    pilot_secret = next(d for d in pilot if d["kind"] == "ExternalSecret")
    entry = next(
        d
        for d in pilot_secret["spec"]["data"]
        if d["secretKey"] == "OPENEXCHANGERATES_APP_ID"
    )
    assert entry == {
        "secretKey": "OPENEXCHANGERATES_APP_ID",
        "sourceRef": {
            "storeRef": {
                "kind": "SecretStore",
                "name": "openbao-homechef-api",
            }
        },
        "remoteRef": {
            "key": "homechef/homechef-api/fe3dr-openexchangerates-app-id",
            "property": "value",
        },
    }
    original = next(
        d
        for d in baseline_secret["spec"]["data"]
        if d["secretKey"] == "OPENEXCHANGERATES_APP_ID"
    )
    assert original == {
        "secretKey": "OPENEXCHANGERATES_APP_ID",
        "remoteRef": {"key": "prod-homechef-openexchangerates-app-id"},
    }
    entry.clear()
    entry.update(original)
    assert pilot == baseline
    assert baseline_secret["spec"]["secretStoreRef"] == {
        "kind": "ClusterSecretStore",
        "name": "gcp-secret-store",
    }
    assert baseline_secret["spec"]["target"]["creationPolicy"] == "Owner"


def test_pilot_defaults_to_gcp_without_environment_opt_in():
    defaults = yaml.safe_load(
        (ROOT / "charts/apps/homechef-api/values.yaml").read_text()
    )
    assert defaults["openbao"]["exchangeRatePilot"]["enabled"] is False


def test_pilot_cannot_read_production_secret_from_another_environment(chart):
    result = subprocess.run(
        [
            "helm",
            "template",
            "homechef-api",
            str(chart),
            "--set",
            "gcp.secretManager.enabled=true",
            "--set",
            "openbao.exchangeRatePilot.enabled=true",
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "exchange-rate pilot is restricted to prod/homechef" in result.stderr
