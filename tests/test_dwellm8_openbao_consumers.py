import json
import subprocess
from pathlib import Path

import yaml
from test_homechef_openbao_access import resource

ROOT = Path(__file__).parents[1]


def render(chart, *values):
    command = [
        "helm",
        "template",
        chart,
        str(ROOT / "charts/apps" / chart),
        "--namespace",
        "dwellm8",
    ]
    for value in values:
        command.extend(["-f", str(ROOT / "charts/apps" / chart / value)])
    return [
        d for d in yaml.safe_load_all(subprocess.check_output(command, text=True)) if d
    ]


def test_dwellm8_bindings_use_openbao_and_preserve_shared_ownership():
    documents = [
        doc
        for chart in ["dwellm8-api", "dwellm8-postgres", "dwellm8-temporal-postgres"]
        for doc in render(chart)
    ]
    documents += render("temporal", "values-dwellm8.yaml")
    catalog = json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
        "dwellm8"
    ]
    for consumer in json.loads((ROOT / "tests/dwellm8-consumers.json").read_text()):
        secret = resource(documents, "ExternalSecret", consumer["name"])
        assert secret["spec"]["target"]["name"] == consumer["target"]
        assert secret["spec"]["secretStoreRef"] == {
            "name": "openbao-dwellm8-production",
            "kind": "SecretStore",
        }
        item = next(
            d for d in secret["spec"]["data"] if d["secretKey"] == consumer["key"]
        )
        assert item["remoteRef"] == {
            "key": catalog[consumer["source"]],
            "property": "value",
        }
    payments = resource(documents, "ExternalSecret", "dwellm8-api-payments")
    for item in payments["spec"]["data"]:
        if (
            item["secretKey"].startswith("CASHFREE_")
            or item["secretKey"] == "RESEND_API_KEY"
        ):
            assert item["sourceRef"]["storeRef"] == {
                "name": "openbao-fe3dr-appdeps",
                "kind": "SecretStore",
            }
            assert item["remoteRef"]["key"].startswith("homechef/homechef-api/fe3dr-")


def test_local_dwellm8_has_no_external_secret_dependency():
    assert not any(
        d["kind"] == "ExternalSecret"
        for d in render("dwellm8-api", "values-local.yaml")
    )


def test_shared_platform_temporal_retains_its_existing_store():
    secret = resource(render("temporal"), "ExternalSecret", "temporal-postgres-auth")
    assert secret["spec"]["secretStoreRef"] == {
        "name": "gcp-secret-store",
        "kind": "ClusterSecretStore",
    }
    assert (
        secret["spec"]["data"][0]["remoteRef"]["key"]
        == "prod-temporal-postgresql-password"
    )
