import sys
import urllib.error
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
import migrate_product_secrets as migration
from migrate_fe3dr_secret import OpenBao


def test_mark8ly_policy_is_exact_and_separates_uat():
    targets = migration.targets_for("mark8ly")
    assert len(targets) == 55
    plan = [{"source": s, "version": "1", "targets": [t]} for s, t in targets.items()]
    policy = migration.policy_for("mark8ly", plan)
    assert "*" not in policy
    assert '"update"' not in policy.split('path "auth/token/')[0]
    assert '"delete"' not in policy
    for source, target in targets.items():
        assert target.startswith(
            "mark8ly-uat/app/mark8ly-"
            if source.startswith("prod-mark8ly-uat-")
            else "mark8ly/app/mark8ly-"
        )
        assert (
            f'path "kv/data/{target}" {{ capabilities = ["create", "read"] }}' in policy
        )


@pytest.mark.parametrize(
    "source,target,version",
    [
        ("prod-ghcr-token", "mark8ly/app/mark8ly-ghcr-token", "1"),
        ("mark8ly-test-private-payment-stripe-api_key", "mark8ly/app/mark8ly-key", "1"),
        (
            "prod-mark8ly-session-encrypt-key",
            "mark8ly-uat/app/mark8ly-session-encrypt-key",
            "1",
        ),
        (
            "prod-mark8ly-session-encrypt-key",
            "mark8ly/app/mark8ly-session-encrypt-key",
            "latest",
        ),
    ],
)
def test_rejects_unreviewed_sources_wrong_scopes_and_unpinned_versions(
    source, target, version
):
    with pytest.raises(ValueError):
        migration.validate_plan(
            "mark8ly", [{"source": source, "version": version, "targets": [target]}]
        )


def test_rejects_unknown_product_and_duplicate_sources():
    with pytest.raises(ValueError):
        migration.targets_for("unknown")
    item = {
        "source": "prod-mark8ly-session-encrypt-key",
        "version": "1",
        "targets": ["mark8ly/app/mark8ly-session-encrypt-key"],
    }
    with pytest.raises(ValueError):
        migration.validate_plan("mark8ly", [item, item])


@pytest.mark.parametrize("scope", ["mark8ly", "mark8ly-uat"])
def test_missing_reviewed_destination_can_be_created(monkeypatch, scope):
    bao = OpenBao("http://127.0.0.1:18200", "synthetic-token")

    def missing(request, timeout):
        raise urllib.error.HTTPError(request.full_url, 404, "not found", {}, None)

    monkeypatch.setattr(bao.opener, "open", missing)
    assert (
        bao.request("GET", f"kv/data/{scope}/app/mark8ly-session-encrypt-key") is None
    )
