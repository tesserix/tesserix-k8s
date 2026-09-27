import json
import re
import sys
from pathlib import Path

from test_homechef_openbao_access import render, resource

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from migrate_product_secrets import targets_for


def test_postiz_reader_and_writer_are_exact_and_namespace_bound():
    targets = targets_for("postiz")
    assert len(targets) == 17
    assert all(t == "postiz/app/" + s.removeprefix("prod-") for s, t in targets.items())
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for name, sa, ns in [
        ("read-postiz-postiz-production", "postiz-production-reader", "postiz"),
        ("postiz-migrate-reviewed", "postiz-migration-writer", "openbao"),
    ]:
        role = json.loads(config[f"role-{name}.json"])
        assert role["bound_service_account_names"] == [sa]
        assert role["bound_service_account_namespaces"] == [ns]
        policy = config[f"policy-{name}.hcl"]
        expected = {
            f"kv/data/{p}"
            for s, p in targets.items()
            if name == "postiz-migrate-reviewed" or s != "prod-postiz-api-key"
        }
        assert set(re.findall(r'path "(kv/data/[^\"]+)"', policy)) == expected
        assert "*" not in policy and '"delete"' not in policy
        if ns == "postiz":
            assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}
        else:
            assert role["token_ttl"] == "15m"
            assert '"update"' not in policy.split('path "auth/token/')[0]
