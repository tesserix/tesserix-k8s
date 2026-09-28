import json
import re
import subprocess

import yaml
from test_homechef_openbao_access import ROOT, render, resource

NAMESPACES = ["homechef", "scrapper", "infra", "temporal-system"]
PATH = "temporal/app/temporal-postgresql-password"


def test_temporal_readers_are_exact_read_only_and_namespace_bound():
    cm = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for ns in NAMESPACES:
        role = json.loads(cm[f"role-read-temporal-{ns}-production.json"])
        assert role["bound_service_account_names"] == ["temporal-production-reader"]
        assert role["bound_service_account_namespaces"] == [ns]
        policy = cm[f"policy-read-temporal-{ns}-production.hcl"]
        assert re.findall(r'path "([^\"]+)"', policy) == ["kv/data/" + PATH]
        assert re.findall(r"capabilities = \[([^]]+)\]", policy) == ['"read"']
    assert json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
        "temporal"
    ] == {"prod-temporal-postgresql-password": PATH}


def test_all_temporal_consumers_preserve_password_key_with_openbao():
    cases = [
        ("temporal", "temporal-postgres-auth", []),
        (
            "temporal",
            "temporal-postgres-auth",
            ["-f", str(ROOT / "charts/apps/temporal/values-homechef.yaml")],
        ),
        ("infra-postgres", "infra-postgres-app", []),
        ("homechef-temporal-postgres", "homechef-temporal-postgres-app", []),
        ("temporal-platform-resources", "temporal-db-credentials", []),
    ]
    for chart, name, args in cases:
        raw = subprocess.check_output(
            ["helm", "template", "test", str(ROOT / "charts/apps" / chart), *args],
            text=True,
        )
        es = resource([d for d in yaml.safe_load_all(raw) if d], "ExternalSecret", name)
        assert es["spec"]["refreshInterval"] == "5m"
        assert es["spec"]["secretStoreRef"] == {
            "name": "openbao-temporal-production",
            "kind": "SecretStore",
        }
        assert es["spec"]["data"] == [
            {"secretKey": "password", "remoteRef": {"key": PATH, "property": "value"}}
        ]


def test_temporal_stores_are_registered_in_each_consumer_namespace():
    p = ROOT / "external-secrets/prod/temporal-openbao-readers.yaml"
    docs = [d for d in yaml.safe_load_all(p.read_text()) if d]
    assert {d["metadata"]["namespace"] for d in docs} == set(NAMESPACES)
    for ns in NAMESPACES:
        store = next(
            d
            for d in docs
            if d["kind"] == "SecretStore" and d["metadata"]["namespace"] == ns
        )
        assert store["spec"]["provider"]["vault"]["auth"]["kubernetes"] == {
            "mountPath": "kubernetes",
            "role": f"read-temporal-{ns}-production",
            "serviceAccountRef": {"name": "temporal-production-reader"},
        }
    assert (
        p.name
        in yaml.safe_load(
            (ROOT / "external-secrets/prod/kustomization.yaml").read_text()
        )["resources"]
    )
