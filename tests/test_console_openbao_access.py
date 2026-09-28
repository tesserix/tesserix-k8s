import json
import re
import subprocess

import yaml
from test_homechef_openbao_access import ROOT, render, resource

TARGETS = {
    "prod-zitadel-console-client-secret": "console/app/console-zitadel-client-secret",
    "prod-console-operator-token-key": "console/app/console-operator-token-key",
    "prod-console-crm-erasure-hash-key": "console/app/console-crm-erasure-hash-key",
    "prod-console-login-throttle-hash-key": "console/app/console-login-throttle-hash-key",
    "prod-console-login-client-token": "console/app/console-zitadel-login-client-token",
    "prod-console-identity-reader-pat": "console/app/console-zitadel-identity-reader-pat",
    "prod-console-entitlements-reader-client-id": "console/app/console-zitadel-entitlements-reader-client-id",
    "prod-console-entitlements-reader-client-secret": "console/app/console-zitadel-entitlements-reader-client-secret",
    "prod-tesserix-stripe-restricted-read-key-test": "console/app/console-stripe-restricted-read-key-test",
    "prod-tesserix-stripe-restricted-read-key-live": "console/app/console-stripe-restricted-read-key-live",
    "prod-tesserix-stripe-write-key-live": "console/app/console-stripe-write-key-live",
    "prod-tesserix-stripe-write-key-test": "console/app/console-stripe-write-key-test",
}


def test_console_reader_and_temporary_writer_are_exact_and_namespace_bound():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for name, sa, caps, ttl in [
        (
            "read-console-tesserix-production",
            "console-production-reader",
            '"read"',
            "1h",
        ),
        (
            "console-migrate-reviewed",
            "console-migration-writer",
            '"create", "read"',
            "15m",
        ),
    ]:
        role = json.loads(config[f"role-{name}.json"])
        assert role["bound_service_account_names"] == [sa]
        assert role["bound_service_account_namespaces"] == ["tesserix"]
        assert role["token_ttl"] == ttl
        policy = config[f"policy-{name}.hcl"]
        assert set(re.findall(r'path "kv/data/([^\"]+)"', policy)) == set(
            TARGETS.values()
        )
        assert "*" not in policy
        for line in policy.splitlines():
            if 'path "kv/data/' in line:
                assert f"capabilities = [{caps}]" in line
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    store = resource(docs, "SecretStore", "openbao-console-production")
    assert store["metadata"]["namespace"] == "tesserix"
    assert store["spec"]["provider"]["vault"]["auth"]["kubernetes"] == {
        "mountPath": "kubernetes",
        "role": "read-console-tesserix-production",
        "serviceAccountRef": {"name": "console-production-reader"},
    }
    for name in ("console-production-reader", "console-migration-writer"):
        sa = resource(docs, "ServiceAccount", name)
        assert sa["metadata"]["namespace"] == "tesserix"
        assert sa["automountServiceAccountToken"] is False
    assert (
        json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
            "console"
        ]
        == TARGETS
    )
