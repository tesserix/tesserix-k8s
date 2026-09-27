import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
import migrate_devai_secrets as migration


def test_only_reviewed_app_paths_receive_create_read():
    assert len(migration.TARGETS) == 38
    assert len(set(migration.TARGETS.values())) == 38
    plan = [
        {"source": source, "version": "1", "targets": [target]}
        for source, target in migration.TARGETS.items()
    ]
    policy = migration.policy_for(plan)
    assert "*" not in policy
    assert '"delete"' not in policy
    for target in migration.TARGETS.values():
        assert target.startswith("devai/app/devai-")
        assert (
            f'path "kv/data/{target}" {{ capabilities = ["create", "read"] }}' in policy
        )


@pytest.mark.parametrize(
    "source,target,version",
    [
        ("prod-ghcr-token", "devai/app/devai-ghcr-token", "1"),
        (
            "devai-user-synthetic-llm-default-openai_api_key",
            "devai/app/devai-user-key",
            "1",
        ),
        ("prod-devai-openai-api-key", "kora/app/kora-openai-api-key", "1"),
        ("prod-devai-openai-api-key", "devai/app/devai-openai-api-key", "latest"),
        ("prod-devai-openai-api-key", "devai/devai-api/owner/devai-key", "1"),
    ],
)
def test_rejects_platform_user_other_product_and_unpinned_sources(
    source, target, version
):
    with pytest.raises(ValueError):
        migration.validate_plan(
            [{"source": source, "version": version, "targets": [target]}]
        )


def test_rejects_duplicate_sources():
    item = {
        "source": "prod-devai-openai-api-key",
        "version": "1",
        "targets": ["devai/app/devai-openai-api-key"],
    }
    with pytest.raises(ValueError):
        migration.validate_plan([item, item])
