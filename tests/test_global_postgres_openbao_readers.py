import json
import re

from test_homechef_openbao_access import render, resource

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

