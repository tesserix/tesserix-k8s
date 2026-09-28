import json
import re
import subprocess

import yaml
from test_homechef_openbao_access import ROOT, render, resource

PATHS = [
    f"kv/data/beautyandcruor/app/beautyandcruor-admin-{key}"
    for key in ["password-hash", "session-key", "github-token"]
]


def test_beautyandcruor_access_scoped_and_registered():
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
    for namespace, role, sa, capabilities in [
        (
            "tesserix",
            "read-beautyandcruor-tesserix-production",
            "beautyandcruor-production-reader",
            '["read"]',
        ),
    ]:
        auth = json.loads(config[f"role-{role}.json"])
        assert auth["bound_service_account_names"] == [sa]
        assert auth["bound_service_account_namespaces"] == [namespace]
        policy = config[f"policy-{role}.hcl"]
        assert set(re.findall(r'path "(kv/data/[^\"]+)"', policy)) == set(PATHS)
        assert "*" not in policy and '"delete"' not in policy
        assert f"capabilities = {capabilities}" in policy
        assert any(
            d["kind"] == "ServiceAccount"
            and d["metadata"]["name"] == sa
            and d["metadata"]["namespace"] == namespace
            for d in docs
        )
        if namespace == "tesserix":
            store = next(
                d
                for d in docs
                if d["kind"] == "SecretStore"
                and d["metadata"]["name"] == "openbao-beautyandcruor-production"
            )
            assert store["metadata"]["namespace"] == namespace
            assert (
                store["spec"]["provider"]["vault"]["auth"]["kubernetes"]["role"] == role
            )


def test_temporary_writer_retired():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    assert "role-beautyandcruor-migrate-reviewed.json" not in config
    assert "policy-beautyandcruor-migrate-reviewed.hcl" not in config
    manifests = subprocess.check_output(
        ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
    )
    assert "beautyandcruor-migration-writer" not in manifests
