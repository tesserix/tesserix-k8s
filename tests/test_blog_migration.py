import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
import migrate_blog_secrets as migration


def test_only_pinned_reviewed_blog_paths_receive_create_read():
    plan = [
        {
            "source": "prod-blog-session-secret",
            "version": "1",
            "targets": ["blog/app/blog-session-secret"],
        }
    ]
    assert (
        'path "kv/data/blog/app/blog-session-secret" { capabilities = ["create", "read"] }'
        in migration.policy_for(plan)
    )
    assert "*" not in migration.policy_for(plan)
    assert '"delete"' not in migration.policy_for(plan)


@pytest.mark.parametrize(
    "source,target,version",
    [
        ("prod-ghcr-token", "blog/app/blog-ghcr-token", "1"),
        ("prod-blog-session-secret", "homechef/homechef-api/blog-session-secret", "1"),
        ("prod-blog-session-secret", "blog/app/blog-session-secret", "latest"),
        ("dev-blog-session-secret", "blog/app/blog-session-secret", "1"),
    ],
)
def test_rejects_platform_other_product_unpinned_and_unreviewed_sources(
    source, target, version
):
    with pytest.raises(ValueError):
        migration.validate_plan(
            [{"source": source, "version": version, "targets": [target]}]
        )


def test_missing_blog_destination_can_be_created(monkeypatch):
    import urllib.error
    from migrate_fe3dr_secret import OpenBao

    bao = OpenBao("http://127.0.0.1:18200", "synthetic-token")

    def missing(request, timeout):
        raise urllib.error.HTTPError(request.full_url, 404, "not found", {}, None)

    monkeypatch.setattr(bao.opener, "open", missing)
    assert bao.request("GET", "kv/data/blog/app/blog-session-secret") is None
