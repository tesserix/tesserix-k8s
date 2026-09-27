import json
from pathlib import Path

from test_homechef_openbao_access import render, resource

ROOT = Path(__file__).parents[1]


def test_postiz_bindings_preserve_targets_and_use_namespaced_openbao():
    documents = render("charts/apps/postiz") + render("charts/apps/postiz-postgres")
    catalog = json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
        "postiz"
    ]
    for consumer in json.loads((ROOT / "tests/postiz-consumers.json").read_text()):
        secret = resource(documents, "ExternalSecret", consumer["name"])
        assert secret["spec"]["target"]["name"] == consumer["target"]
        assert secret["spec"]["secretStoreRef"] == {
            "name": "openbao-postiz-production",
            "kind": "SecretStore",
        }
        item = next(
            d for d in secret["spec"]["data"] if d["secretKey"] == consumer["key"]
        )
        assert item["remoteRef"] == {
            "key": catalog[consumer["source"]],
            "property": "value",
        }
    registry = resource(documents, "ExternalSecret", "ghcr-secret")
    assert registry["spec"]["secretStoreRef"]["name"] == "gcp-secret-store"
