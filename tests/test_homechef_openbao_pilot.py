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


def render(chart, enabled, static=False, coordinated=False):
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
            "--set",
            f"openbao.staticSecrets.enabled={str(static).lower()}",
            "--set",
            f"openbao.coordinatedSecrets.enabled={str(coordinated).lower()}",
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


STATIC_KEYS = {
    "OPENEXCHANGERATES_APP_ID": "openexchangerates-app-id",
    "EXCHANGERATES_API_KEY": "exchangerates-api-key",
    "GOOGLE_MAPS_API_KEY": "google-maps-api-key",
    "MAPPLS_CLIENT_ID": "mappls-client-id",
    "MAPPLS_CLIENT_SECRET": "mappls-client-secret",
    "DELIVERY_SURGE_PIN_KEY": "delivery-surge-pin-key",
    "JWT_SECRET": "jwt-secret",
    "JWT_REFRESH_SECRET": "jwt-refresh-secret",
    "SUPER_ADMIN_EMAILS": "admin-allowed-emails",
    "APPLE_KEY_ID": "apple-key-id",
    "APPLE_SIGNIN_PRIVATE_KEY_B64": "apple-signin-private-key-b64",
}


def test_static_batch_moves_only_reviewed_keys_and_preserves_all_other_resources(chart):
    baseline = render(chart, False)
    migrated = render(chart, False, static=True)
    old = next(d for d in baseline if d["kind"] == "ExternalSecret")
    new = next(d for d in migrated if d["kind"] == "ExternalSecret")
    original = {d["secretKey"]: d for d in old["spec"]["data"]}
    for entry in new["spec"]["data"]:
        key = entry["secretKey"]
        if key not in STATIC_KEYS:
            assert entry == original[key]
            continue
        assert entry["sourceRef"]["storeRef"] == {
            "kind": "SecretStore",
            "name": "openbao-homechef-api",
        }
        assert entry["remoteRef"] == {
            "key": "homechef/homechef-api/fe3dr-" + STATIC_KEYS[key],
            "property": "value",
        }
        entry.clear()
        entry.update(original[key])
    assert migrated == baseline


def test_bff_static_keys_use_its_own_store_and_prefix():
    docs = list(
        yaml.safe_load_all(
            (ROOT / "external-secrets/prod/homechef/externalsecret.yaml").read_text()
        )
    )
    resource = next(
        d for d in docs if d["metadata"]["name"] == "homechef-auth-bff-secrets"
    )
    expected = {
        "SESSION_ENCRYPT_KEY": "session-encrypt-key",
        "HOMECHEF_ADMIN_ALLOWED_EMAILS": "admin-allowed-emails",
        "BFF_INTERNAL_HMAC_KEY": "bff-internal-hmac-key",
    }
    for entry in resource["spec"]["data"]:
        if entry["secretKey"] in expected:
            assert entry["sourceRef"]["storeRef"] == {
                "kind": "SecretStore",
                "name": "openbao-homechef-auth-bff",
            }
            assert entry["remoteRef"] == {
                "key": "homechef/homechef-auth-bff/fe3dr-"
                + expected[entry["secretKey"]],
                "property": "value",
            }
        else:
            assert "sourceRef" not in entry


def test_coordinated_api_batch_preserves_static_and_shared_entries(chart):
    baseline = render(chart, False)
    changed = render(chart, False, coordinated=True)
    original = next(d for d in baseline if d["kind"] == "ExternalSecret")
    current = next(d for d in changed if d["kind"] == "ExternalSecret")
    keys = {
        "DB_PASSWORD": "postgresql-password",
        "BFF_INTERNAL_HMAC_KEY": "bff-internal-hmac-key",
        "GOOGLE_WEATHER_API_KEY": "google-weather-api-key",
    }
    originals = {e["secretKey"]: e for e in original["spec"]["data"]}
    for entry in current["spec"]["data"]:
        if entry["secretKey"] in keys:
            assert entry["sourceRef"]["storeRef"] == {
                "kind": "SecretStore",
                "name": "openbao-homechef-api",
            }
            assert entry["remoteRef"] == {
                "key": "homechef/homechef-api/fe3dr-" + keys[entry["secretKey"]],
                "property": "value",
            }
            old = originals[entry["secretKey"]]
            entry.clear()
            entry.update(old)
    assert changed == baseline


def test_fully_migrated_api_uses_openbao_for_own_and_shared_secrets(chart):
    docs = render(chart, True, static=True, coordinated=True)
    spec = next(d for d in docs if d["kind"] == "ExternalSecret")["spec"]
    assert spec["secretStoreRef"] == {
        "kind": "SecretStore",
        "name": "openbao-homechef-api",
    }
    for entry in spec["data"]:
        store = entry.get("sourceRef", {}).get("storeRef", spec["secretStoreRef"])
        if entry["secretKey"] in {"RESEND_API_KEY", "GITHUB_FEEDBACK_TOKEN"}:
            assert store == {"kind": "SecretStore", "name": "openbao-fe3dr-appdeps"}
        else:
            assert store == spec["secretStoreRef"]
            assert entry["remoteRef"]["key"].startswith("homechef/homechef-api/fe3dr-")
            assert entry["remoteRef"]["property"] == "value"


def test_all_bff_bundle_entries_default_to_its_own_openbao_prefix():
    docs = list(
        yaml.safe_load_all(
            (ROOT / "external-secrets/prod/homechef/externalsecret.yaml").read_text()
        )
    )
    spec = next(
        d for d in docs if d["metadata"]["name"] == "homechef-auth-bff-secrets"
    )["spec"]
    assert spec["secretStoreRef"] == {
        "kind": "SecretStore",
        "name": "openbao-homechef-auth-bff",
    }
    assert len(spec["data"]) == 7
    for entry in spec["data"]:
        assert (
            entry.get("sourceRef", {}).get("storeRef", spec["secretStoreRef"])
            == spec["secretStoreRef"]
        )
        assert entry["remoteRef"]["key"].startswith("homechef/homechef-auth-bff/fe3dr-")
        assert entry["remoteRef"]["property"] == "value"
