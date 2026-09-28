import json
import re
import subprocess
from pathlib import Path

import yaml
from test_homechef_openbao_access import render, resource

ROOT = Path(__file__).parents[1]


def test_planning_poker_access_is_scoped_and_registered():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    for ns, role, sa in [
        (
            "planning-poker",
            "read-planning-poker-planning-poker-production",
            "planning-poker-production-reader",
        ),
    ]:
        auth = json.loads(config[f"role-{role}.json"])
        assert auth["bound_service_account_names"] == [sa]
        assert auth["bound_service_account_namespaces"] == [ns]
        policy = config[f"policy-{role}.hcl"]
        assert re.findall(r'path "(kv/data/[^\"]+)"', policy) == [
            "kv/data/planning-poker/app/planning-poker-token-secret"
        ]
        assert '"delete"' not in policy and "*" not in policy
        assert any(
            d["kind"] == "ServiceAccount"
            and d["metadata"]["name"] == sa
            and d["metadata"]["namespace"] == ns
            for d in docs
        )
        if ns == "planning-poker":
            assert 'capabilities = ["read"]' in policy
            store = next(
                d
                for d in docs
                if d["kind"] == "SecretStore"
                and d["metadata"]["name"] == "openbao-planning-poker-production"
            )
            assert (
                store["spec"]["provider"]["vault"]["auth"]["kubernetes"]["role"] == role
            )


def test_temporary_migration_access_retired():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    assert "role-planning-poker-migrate-reviewed.json" not in config
    assert "policy-planning-poker-migrate-reviewed.hcl" not in config
    manifests = subprocess.check_output(
        ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
    )
    assert "planning-poker-migration-writer" not in manifests
