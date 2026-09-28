import json
import re

import yaml
from test_homechef_openbao_access import ROOT, render, resource


def test_typesense_reader_has_one_read_only_path_and_namespace():
    cm = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    role = json.loads(cm["role-read-typesense-production.json"])
    assert role["bound_service_account_names"] == ["typesense-production-reader"]
    assert role["bound_service_account_namespaces"] == ["typesense"]
    assert role["token_policies"] == ["read-typesense-production"]
    policy = cm["policy-read-typesense-production.hcl"]
    assert re.findall(r'path "([^\"]+)"', policy) == [
        "kv/data/typesense/app/typesense-api-key"
    ]
    assert re.findall(r"capabilities = \[([^]]+)\]", policy) == ['"read"']
    assert json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
        "typesense"
    ] == {"prod-typesense-api-key": "typesense/app/typesense-api-key"}


def test_typesense_consumer_preserves_key_and_uses_namespace_reader():
    es = yaml.safe_load(
        (ROOT / "external-secrets/prod/typesense/externalsecret.yaml").read_text()
    )
    assert es["spec"]["secretStoreRef"] == {
        "name": "openbao-typesense-production",
        "kind": "SecretStore",
    }
    assert es["spec"]["refreshInterval"] == "5m"
    assert es["spec"]["target"]["name"] == "typesense-secrets"
    assert es["spec"]["data"] == [
        {
            "secretKey": "api-key",
            "remoteRef": {
                "key": "typesense/app/typesense-api-key",
                "property": "value",
            },
        }
    ]
    readers = list(
        yaml.safe_load_all(
            (ROOT / "external-secrets/prod/typesense-openbao-readers.yaml").read_text()
        )
    )
    store = resource(readers, "SecretStore", "openbao-typesense-production")
    assert store["metadata"]["namespace"] == "typesense"
    assert store["spec"]["provider"]["vault"]["auth"]["kubernetes"] == {
        "mountPath": "kubernetes",
        "role": "read-typesense-production",
        "serviceAccountRef": {"name": "typesense-production-reader"},
    }
    assert (
        "typesense-openbao-readers.yaml"
        in yaml.safe_load(
            (ROOT / "external-secrets/prod/kustomization.yaml").read_text()
        )["resources"]
    )
