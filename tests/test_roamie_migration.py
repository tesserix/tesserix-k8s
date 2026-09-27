import importlib.util
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location(
    "roamie_migration", ROOT / "scripts/migrate_roamie_secrets.py"
)
batch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(batch)


def test_scoped_policy_allows_creation_and_read_but_not_rotation_or_deletion():
    plan = [
        {
            "source": "prod-roamie-api-ocr-key",
            "version": "2",
            "targets": ["roamie/app/roamie-api-ocr-key"],
        }
    ]
    policy = batch.policy_for(plan)
    assert 'path "kv/data/roamie/app/roamie-api-ocr-key"' in policy
    assert 'capabilities = ["create", "read"]' in policy
    assert "*" not in policy
    assert '"delete"' not in policy


@pytest.mark.parametrize(
    "source,target,version",
    [
        ("prod-ghcr-token", "roamie/app/roamie-ghcr-token", "1"),
        ("prod-roamie-api-ocr-key", "platform/roamie-api-ocr-key", "1"),
        ("dev-roamie-api-ocr-key", "roamie/app/roamie-api-ocr-key", "1"),
        ("prod-roamie-api-ocr-key", "roamie/app/roamie-api-ocr-key", "latest"),
        ("prod-roamie-unknown", "roamie/app/roamie-unknown", "1"),
    ],
)
def test_rejects_platform_paths_environment_mixups_aliases_and_unreviewed_names(
    source, target, version
):
    with pytest.raises(ValueError):
        batch.validate_plan(
            [{"source": source, "version": version, "targets": [target]}]
        )


def test_development_and_shared_product_sources_have_canonical_paths():
    assert (
        batch.destination("dev-roamie-api-ocr-key")
        == "roamie-development/app/roamie-api-ocr-key"
    )
    assert (
        batch.destination("prod-agentic-registry-roamie-deploy-key")
        == "roamie/app/roamie-registry-deploy-key"
    )
    assert (
        batch.destination("prod-document-intelligence-roamie-db-password")
        == "roamie/app/roamie-document-intelligence-db-password"
    )
    item = {
        "source": "prod-roamie-api-ocr-key",
        "version": "1",
        "targets": ["roamie/app/roamie-api-ocr-key"],
    }
    with pytest.raises(ValueError):
        batch.validate_plan([item, item])


@pytest.mark.parametrize("prefix", ["roamie", "roamie-development"])
def test_missing_roamie_destination_can_be_created(prefix, monkeypatch):
    import urllib.error
    from migrate_fe3dr_secret import OpenBao

    bao = OpenBao("http://127.0.0.1:18200", "synthetic-token")

    def missing(request, timeout):
        raise urllib.error.HTTPError(request.full_url, 404, "not found", {}, None)

    monkeypatch.setattr(bao.opener, "open", missing)
    assert bao.request("GET", "kv/data/" + prefix + "/app/roamie-api-ocr-key") is None
