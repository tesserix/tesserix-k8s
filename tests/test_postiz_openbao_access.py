import json
import re
import sys
from pathlib import Path

from test_homechef_openbao_access import render, resource

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from migrate_product_secrets import targets_for


def test_postiz_reader_is_exact_and_temporary_writer_is_retired():
    targets = targets_for("postiz")
    assert len(targets) == 17
    assert all(t == "postiz/app/" + s.removeprefix("prod-") for s, t in targets.items())
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    assert "role-postiz-migrate-reviewed.json" not in config
    assert "policy-postiz-migrate-reviewed.hcl" not in config
    name = "read-postiz-postiz-production"
    role = json.loads(config[f"role-{name}.json"])
    assert role["bound_service_account_names"] == ["postiz-production-reader"]
    assert role["bound_service_account_namespaces"] == ["postiz"]
    policy = config[f"policy-{name}.hcl"]
    expected = {
        f"kv/data/{p}" for s, p in targets.items() if s != "prod-postiz-api-key"
    }
    assert set(re.findall(r'path "(kv/data/[^"]+)"', policy)) == expected
    assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}
