import json
import re
import sys
from pathlib import Path

import yaml
from test_homechef_openbao_access import render, resource

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from migrate_product_secrets import targets_for


def test_support_platform_access_is_exact_and_namespace_bound():
    targets = targets_for("support-platform")
    assert len(targets) == 4
    assert all(
        t == "support-platform/app/" + s.removeprefix("prod-")
        for s, t in targets.items()
    )
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    docs = list(
        yaml.safe_load_all(
            (
                ROOT / "external-secrets/prod/support-platform-openbao-readers.yaml"
            ).read_text()
        )
    )
    for ns in ["support-platform", "agentgateway-system", "openbao"]:
        writer = ns == "openbao"
        name = (
            "support-platform-migrate-reviewed"
            if writer
            else f"read-support-platform-{ns}-production"
        )
        sa = (
            "support-platform-migration-writer"
            if writer
            else "support-platform-production-reader"
        )
        role = json.loads(config[f"role-{name}.json"])
        assert role["bound_service_account_names"] == [sa]
        assert role["bound_service_account_namespaces"] == [ns]
        policy = config[f"policy-{name}.hcl"]
        expected = {
            f"kv/data/{t}"
            for s, t in targets.items()
            if ns != "agentgateway-system" or s.endswith("platform-mcp-key")
        }
        assert set(re.findall(r'path "(kv/data/[^\"]+)"', policy)) == expected
        assert "*" not in policy and '"delete"' not in policy
        assert (
            next(
                d
                for d in docs
                if d["kind"] == "ServiceAccount"
                and d["metadata"] == {"name": sa, "namespace": ns}
            )["automountServiceAccountToken"]
            is False
        )
        if writer:
            assert role["token_ttl"] == "15m"
            assert '"update"' not in policy.split('path "auth/token/')[0]
        else:
            assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}
            store = next(
                d
                for d in docs
                if d["kind"] == "SecretStore" and d["metadata"]["namespace"] == ns
            )
            assert (
                store["spec"]["provider"]["vault"]["auth"]["kubernetes"]["role"] == name
            )
