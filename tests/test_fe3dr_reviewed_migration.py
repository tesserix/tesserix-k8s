import importlib.util
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location(
    "batch", ROOT / "scripts/migrate_fe3dr_reviewed.py"
)
batch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(batch)


def test_reviewed_plan_generates_only_exact_create_read_paths():
    plan = [
        {
            "source": "prod-homechef-jwt-secret",
            "version": "1",
            "targets": ["homechef/homechef-api/fe3dr-jwt-secret"],
        }
    ]
    batch.validate_plan(plan)
    policy = batch.policy_for(plan)
    assert 'path "kv/data/homechef/homechef-api/fe3dr-jwt-secret"' in policy
    assert 'capabilities = ["create", "read"]' in policy
    assert "*" not in policy
    assert '"delete"' not in policy


@pytest.mark.parametrize(
    "source,target",
    [
        ("prod-ghcr-token", "homechef/homechef-api/fe3dr-ghcr-token"),
        ("prod-homechef-jwt-secret", "platform/fe3dr-jwt-secret"),
        ("prod-homechef-jwt-secret", "homechef/homechef-api/fe3dr-other"),
        (
            "prod-homechef-cloudflare-api-token",
            "homechef/homechef-api/fe3dr-cloudflare-api-token",
        ),
        ("prod-homechef-jwt-secret", "homechef/homechef-api/../fe3dr-jwt-secret"),
    ],
)
def test_plan_rejects_platform_or_inconsistent_paths(source, target):
    with pytest.raises(ValueError):
        batch.validate_plan([{"source": source, "version": "1", "targets": [target]}])


def test_plan_rejects_aliases_and_duplicate_sources():
    item = {
        "source": "prod-homechef-jwt-secret",
        "version": "latest",
        "targets": ["homechef/homechef-api/fe3dr-jwt-secret"],
    }
    with pytest.raises(ValueError):
        batch.validate_plan([item])
    item["version"] = "1"
    with pytest.raises(ValueError):
        batch.validate_plan([item, item])
