import json
from pathlib import Path

import yaml

ROOT = Path(__file__).parents[1]


def test_all_reviewed_support_platform_bindings_use_openbao():
    catalog = json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
        "support-platform"
    ]
    bindings = json.loads((ROOT / "tests/support-platform-consumers.json").read_text())
    assert len(bindings) == 6
    documents = [
        doc
        for ns in ("support-platform", "agentgateway-system")
        for doc in yaml.safe_load_all(
            (ROOT / f"external-secrets/prod/{ns}/externalsecret.yaml").read_text()
        )
        if doc
    ]
    for binding in bindings:
        doc = next(
            d
            for d in documents
            if d["metadata"]["name"] == binding["name"]
            and d["metadata"]["namespace"] == binding["namespace"]
        )
        assert doc["spec"]["target"]["name"] == binding["target"]
        item = next(d for d in doc["spec"]["data"] if d["secretKey"] == binding["key"])
        assert item["remoteRef"] == {
            "key": catalog[binding["source"]],
            "property": "value",
        }
        assert item.get("sourceRef", {}).get(
            "storeRef", doc["spec"]["secretStoreRef"]
        ) == {"name": "openbao-support-platform-production", "kind": "SecretStore"}
