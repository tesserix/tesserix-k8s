import json
import re
import sys
from pathlib import Path

import yaml
from test_homechef_openbao_access import render, resource

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
CONSUMERS = json.loads((ROOT / "tests/mark8ly-consumers.json").read_text())


def test_readers_only_access_their_namespace_app_dependencies():
    from migrate_product_secrets import targets_for

    TARGETS = targets_for("mark8ly")

    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for namespace in sorted({item["namespace"] for item in CONSUMERS}):
        name = f"read-mark8ly-{namespace}-production"
        role = json.loads(config[f"role-{name}.json"])
        assert role["bound_service_account_namespaces"] == [namespace]
        assert role["bound_service_account_names"] == ["mark8ly-production-reader"]
        assert role["token_policies"] == [name]
        policy = config[f"policy-{name}.hcl"]
        assert set(re.findall(r'path "([^"]+)"', policy)) == {
            "kv/data/" + TARGETS[item["source"]]
            for item in CONSUMERS
            if item["namespace"] == namespace
        }
        assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}


def test_temporary_writer_only_creates_reviewed_paths():
    from migrate_product_secrets import targets_for

    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    role = json.loads(config["role-mark8ly-migrate-reviewed.json"])
    assert role["bound_service_account_namespaces"] == ["openbao"]
    assert role["bound_service_account_names"] == ["mark8ly-migration-writer"]
    assert role["token_ttl"] == "15m"
    policy = config["policy-mark8ly-migrate-reviewed.hcl"]
    assert set(re.findall(r'path "(kv/data/[^"]+)"', policy)) == {
        "kv/data/" + p for p in targets_for("mark8ly").values()
    }
    assert '"delete"' not in policy and "*" not in policy


def test_stores_are_namespaced_and_included_in_gitops():
    stores = list(
        yaml.safe_load_all(
            (ROOT / "external-secrets/prod/mark8ly-openbao-readers.yaml").read_text()
        )
    )
    assert len(stores) == 13
    assert (
        sum(doc["metadata"]["name"] == "mark8ly-migration-writer" for doc in stores)
        == 1
    )
    for namespace in {item["namespace"] for item in CONSUMERS}:
        docs = [doc for doc in stores if doc["metadata"]["namespace"] == namespace]
        assert (
            resource(docs, "ServiceAccount", "mark8ly-production-reader")[
                "automountServiceAccountToken"
            ]
            is False
        )
        store = resource(docs, "SecretStore", "openbao-mark8ly-production")
        vault = store["spec"]["provider"]["vault"]
        assert vault["path"] == "kv"
        assert vault["version"] == "v2"
        auth = vault["auth"]["kubernetes"]
        assert auth["role"] == f"read-mark8ly-{namespace}-production"
        assert auth["serviceAccountRef"]["name"] == "mark8ly-production-reader"
    kustomization = yaml.safe_load(
        (ROOT / "external-secrets/prod/kustomization.yaml").read_text()
    )
    assert "mark8ly-openbao-readers.yaml" in kustomization["resources"]
