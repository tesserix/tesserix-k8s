import json
import re
import subprocess

import yaml
from test_homechef_openbao_access import ROOT, render, resource

PATH = "global-postgres/app/global-postgres-password"


def test_global_postgres_readers_are_exact_read_only_and_namespace_bound():
    cm = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for ns in ["global", "db-backup-and-restore"]:
        name = f"read-global-postgres-{ns}-production"
        role = json.loads(cm[f"role-{name}.json"])
        assert role["bound_service_account_names"] == [
            "global-postgres-production-reader"
        ]
        assert role["bound_service_account_namespaces"] == [ns]
        policy = cm[f"policy-{name}.hcl"]
        assert re.findall(r'path "([^\"]+)"', policy) == ["kv/data/" + PATH]
        assert re.findall(r"capabilities = \[([^]]+)\]", policy) == ['"read"']
    assert json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
        "global-postgres"
    ] == {"prod-global-postgresql-password": PATH}


def test_global_postgres_consumers_preserve_their_existing_password_keys():
    cases = [
        ("global-postgres", "global-postgres-app-credentials", "password", []),
        (
            "db-schema-bootstrap",
            "postgresql-password",
            "postgresql-password",
            ["--set", "app=global"],
        ),
    ]
    secrets = []
    for chart, name, key, args in cases:
        raw = subprocess.check_output(
            ["helm", "template", "test", str(ROOT / "charts/apps" / chart), *args],
            text=True,
        )
        secrets.append(
            (
                resource(
                    [d for d in yaml.safe_load_all(raw) if d], "ExternalSecret", name
                ),
                key,
            )
        )
    docs = list(
        yaml.safe_load_all(
            (
                ROOT / "external-secrets/prod/db-backup-and-restore/externalsecret.yaml"
            ).read_text()
        )
    )
    secrets.append(
        (
            resource(docs, "ExternalSecret", "postgresql-global-password"),
            "postgresql-password",
        )
    )
    for es, key in secrets:
        assert es["spec"]["secretStoreRef"] == {
            "name": "openbao-global-postgres-production",
            "kind": "SecretStore",
        }
        assert es["spec"]["refreshInterval"] == "5m"
        assert es["spec"]["data"] == [
            {"secretKey": key, "remoteRef": {"key": PATH, "property": "value"}}
        ]
    path = ROOT / "external-secrets/prod/global-postgres-openbao-readers.yaml"
    docs = list(yaml.safe_load_all(path.read_text()))
    assert {d["metadata"]["namespace"] for d in docs} == {
        "global",
        "db-backup-and-restore",
    }
    for d in docs:
        if d["kind"] == "SecretStore":
            assert (
                d["spec"]["provider"]["vault"]["auth"]["kubernetes"]["role"]
                == f"read-global-postgres-{d['metadata']['namespace']}-production"
            )
    assert (
        path.name
        in yaml.safe_load(
            (ROOT / "external-secrets/prod/kustomization.yaml").read_text()
        )["resources"]
    )
