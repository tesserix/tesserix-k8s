import json
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).parents[1]


def test_all_observed_mark8ly_bindings_use_scoped_openbao_paths():
    documents = []
    for command in (
        ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")],
        ["kubectl", "kustomize", str(ROOT / "external-secrets/prod/mark8ly")],
        [
            "helm",
            "template",
            "company",
            str(ROOT / "charts/apps/company"),
            "--namespace",
            "tesserix",
        ],
    ):
        documents.extend(
            yaml.safe_load_all(subprocess.check_output(command, text=True))
        )
    catalog = json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
        "mark8ly"
    ]
    for consumer in json.loads((ROOT / "tests/mark8ly-consumers.json").read_text()):
        resources = [
            d
            for d in documents
            if d
            and d.get("kind") == "ExternalSecret"
            and d["metadata"]["name"] == consumer["name"]
            and d["metadata"].get("namespace", "tesserix") == consumer["namespace"]
        ]
        assert resources, consumer
        for resource in resources:
            item = next(
                d for d in resource["spec"]["data"] if d["secretKey"] == consumer["key"]
            )
            assert item["remoteRef"]["key"] == catalog[consumer["source"]]
            assert item["remoteRef"]["property"] == "value"
            assert item["sourceRef"]["storeRef"] == {
                "kind": "SecretStore",
                "name": "openbao-mark8ly-production",
            }
