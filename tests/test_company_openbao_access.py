import json
import re
import subprocess

import yaml
from test_homechef_openbao_access import ROOT, render, resource

TARGETS = {
    "prod-internal-service-key": "tesserix/app/tesserix-internal-service-key",
    "prod-tesserix-internal-api-token": "tesserix/app/tesserix-internal-api-token",
    "prod-github-token": "tesserix/app/tesserix-github-token",
    "prod-marketplace-content-admin-key": "tesserix/app/tesserix-marketplace-content-admin-key",
    "prod-argocd-auth-token": "tesserix/app/tesserix-argocd-auth-token",
    "prod-tesserix-session-encrypt-key": "tesserix/app/tesserix-session-encrypt-key",
    "prod-tesserix-sendgrid-webhook-secret": "tesserix/app/tesserix-sendgrid-webhook-secret",
}


def test_company_access_is_exact_namespace_bound_and_registered():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    for namespace in ["tesserix", "mark8ly"]:
        role = f"read-tesserix-{namespace}-production"
        auth = json.loads(config[f"role-{role}.json"])
        assert auth["bound_service_account_names"] == ["tesserix-production-reader"]
        assert auth["bound_service_account_namespaces"] == [namespace]
        policy = config[f"policy-{role}.hcl"]
        expected = (
            set(TARGETS.values())
            if namespace == "tesserix"
            else {TARGETS["prod-tesserix-internal-api-token"]}
        )
        assert set(re.findall(r'path "kv/data/([^\"]+)"', policy)) == expected
        assert set(re.findall(r"capabilities = \[([^\]]+)\]", policy)) == {'"read"'}
        assert "*" not in policy
        store = next(
            d
            for d in docs
            if d["kind"] == "SecretStore"
            and d["metadata"]["name"] == "openbao-tesserix-production"
            and d["metadata"]["namespace"] == namespace
        )
        assert store["spec"]["provider"]["vault"]["auth"]["kubernetes"] == {
            "mountPath": "kubernetes",
            "role": role,
            "serviceAccountRef": {"name": "tesserix-production-reader"},
        }
        assert any(
            d["kind"] == "ServiceAccount"
            and d["metadata"]["namespace"] == namespace
            and d["metadata"]["name"] == "tesserix-production-reader"
            and d["automountServiceAccountToken"] is False
            for d in docs
        )


def test_company_writer_cannot_overwrite_or_read_other_products():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    role = json.loads(config["role-tesserix-migrate-reviewed.json"])
    assert role["bound_service_account_names"] == ["tesserix-migration-writer"]
    assert role["bound_service_account_namespaces"] == ["tesserix"]
    assert role["token_ttl"] == "15m"
    policy = config["policy-tesserix-migrate-reviewed.hcl"]
    assert set(re.findall(r'path "kv/data/([^\"]+)"', policy)) == set(TARGETS.values())
    assert "*" not in policy and '"delete"' not in policy
    for line in policy.splitlines():
        if 'path "kv/data/' in line:
            assert 'capabilities = ["create", "read"]' in line
    assert (
        json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
            "tesserix"
        ]
        == TARGETS
    )
