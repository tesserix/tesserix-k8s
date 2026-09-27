import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
import migrate_kora_secrets as migration


def test_only_pinned_reviewed_kora_paths_receive_create_read():
    plan = [
        {
            "source": "prod-kora-mcp-internal-key",
            "version": "1",
            "targets": ["kora/app/kora-mcp-internal-key"],
        }
    ]
    assert (
        'path "kv/data/kora/app/kora-mcp-internal-key" { capabilities = ["create", "read"] }'
        in migration.policy_for(plan)
    )
    assert "*" not in migration.policy_for(plan)
    assert '"delete"' not in migration.policy_for(plan)


@pytest.mark.parametrize(
    "source,target,version",
    [
        ("prod-ghcr-token", "kora/app/kora-ghcr-token", "1"),
        ("prod-kora-mcp-internal-key", "homechef/homechef-api/kora-mcp-internal-key", "1"),
        ("prod-kora-mcp-internal-key", "kora/app/kora-mcp-internal-key", "latest"),
        ("dev-kora-mcp-internal-key", "kora/app/kora-mcp-internal-key", "1"),
    ],
)
def test_rejects_platform_other_product_unpinned_and_unreviewed_sources(
    source, target, version
):
    with pytest.raises(ValueError):
        migration.validate_plan(
            [{"source": source, "version": version, "targets": [target]}]
        )


def test_missing_kora_destination_can_be_created(monkeypatch):
    import urllib.error
    from migrate_fe3dr_secret import OpenBao

    bao = OpenBao("http://127.0.0.1:18200", "synthetic-token")

    def missing(request, timeout):
        raise urllib.error.HTTPError(request.full_url, 404, "not found", {}, None)

    monkeypatch.setattr(bao.opener, "open", missing)
    assert bao.request("GET", "kv/data/kora/app/kora-mcp-internal-key") is None
