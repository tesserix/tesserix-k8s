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


@pytest.mark.parametrize("suffix", [
    "gip-web-api-key", "customer-client-secret", "business-client-secret", "internal-client-secret",
])
def test_reviewed_bff_identity_entries_use_product_prefixed_paths(suffix):
    plan = [{"source": "prod-homechef-" + suffix, "version": "1",
             "targets": ["homechef/homechef-auth-bff/fe3dr-" + suffix]}]
    batch.validate_plan(plan)
    policy = batch.policy_for(plan)
    assert 'path "kv/data/homechef/homechef-auth-bff/fe3dr-' + suffix + '"' in policy
    assert '"update"' not in policy.split('path "auth/token/lookup-self"')[0]


@pytest.mark.parametrize("source,suffix", [
    ("prod-homechef-bff-backup-code-hmac-key", "bff-backup-code-hmac-key"),
    ("prod-homechef-bff-csrf-secret", "bff-csrf-secret"),
    ("prod-homechef-bff-session-secret", "bff-session-secret"),
    ("prod-homechef-bff-totp-encryption-key", "bff-totp-encryption-key"),
    ("prod-homechef-keycloak-client-secret", "keycloak-client-secret"),
    ("prod-homechef-internal-keycloak-client-secret", "internal-keycloak-client-secret"),
    ("prod-homechef-razorpay-key-id", "razorpay-key-id"),
    ("prod-homechef-razorpay-key-secret", "razorpay-key-secret"),
    ("prod-homechef-razorpay-webhook-secret", "razorpay-webhook-secret"),
    ("prod-homechef-razorpay-test-key-id", "razorpay-test-key-id"),
    ("prod-homechef-razorpay-test-key-secret", "razorpay-test-key-secret"),
    ("prod-homechef-razorpay-test-webhook-secret", "razorpay-test-webhook-secret"),
    ("prod-homechef-google-places-api-key", "google-places-api-key"),
    ("prod-homechef-postgresql-url", "postgresql-url"),
    ("shadowfax-api-token", "shadowfax-api-token"),
])
def test_reviewed_legacy_app_names_can_be_staged_without_platform_access(source, suffix):
    assert batch.identifier(source) == "fe3dr-" + suffix
    app = "homechef-auth-bff" if suffix.startswith("bff-") else "homechef-api"
    plan = [{"source": source, "version": "1", "targets": [f"homechef/{app}/fe3dr-{suffix}"]}]
    policy = batch.policy_for(plan)
    assert 'capabilities = ["create", "read"]' in policy
    assert "*" not in policy
    assert '"delete"' not in policy
