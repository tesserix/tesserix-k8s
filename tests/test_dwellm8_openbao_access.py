import json
import re
import sys
from pathlib import Path

from test_homechef_openbao_access import render, resource

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from migrate_product_secrets import targets_for


def test_dwellm8_reader_is_exact_and_temporary_writer_is_retired():
    targets = targets_for("dwellm8")
    assert len(targets) == 10
    assert all(
        t == "dwellm8/app/" + s.removeprefix("prod-") for s, t in targets.items()
    )
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    assert "role-dwellm8-migrate-reviewed.json" not in config
    assert "policy-dwellm8-migrate-reviewed.hcl" not in config
    name = "read-dwellm8-dwellm8-production"
    role = json.loads(config[f"role-{name}.json"])
    assert role["bound_service_account_names"] == ["dwellm8-production-reader"]
    assert role["bound_service_account_namespaces"] == ["dwellm8"]
    policy = config[f"policy-{name}.hcl"]
    expected = {f"kv/data/{p}" for s, p in targets.items()}
    assert set(re.findall(r'path "(kv/data/[^"]+)"', policy)) == expected
    assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}
