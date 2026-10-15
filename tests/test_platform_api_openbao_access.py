import json
import re
import subprocess

import yaml
from test_homechef_openbao_access import ROOT, render, resource

# The GitHub App key that can publish or archive any org repository. Readable
# by platform-api's own role and nothing broader.
PATHS = {
    "platform-api/app/platform-api-repos-github-app-id",
    "platform-api/app/platform-api-repos-github-app-installation-id",
    "platform-api/app/platform-api-repos-github-app-private-key",
}


def test_platform_api_reader_is_exact_read_only_and_namespace_bound():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    name = "read-platform-api-tesserix-production"
    role = json.loads(config[f"role-{name}.json"])
    assert role["bound_service_account_names"] == ["platform-api-production-reader"]
    assert role["bound_service_account_namespaces"] == ["tesserix"]
    assert role["token_ttl"] == "1h"
    policy = config[f"policy-{name}.hcl"]
    assert set(re.findall(r'path "kv/data/([^"]+)"', policy)) == PATHS
    assert "*" not in policy
    for line in policy.splitlines():
        if 'path "kv/data/' in line:
            assert 'capabilities = ["read"]' in line


def test_no_other_reader_can_read_the_app_key():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for key, policy in config.items():
        if not key.startswith("policy-read-") or key == "policy-read-platform-api-tesserix-production.hcl":
            continue
        assert "platform-api/app/platform-api-repos-github-app" not in policy, key


def test_store_and_external_secret_are_wired_to_the_reader():
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    store = resource(docs, "SecretStore", "openbao-platform-api-production")
    assert store["metadata"]["namespace"] == "tesserix"
    assert store["spec"]["provider"]["vault"]["auth"]["kubernetes"] == {
        "mountPath": "kubernetes",
        "role": "read-platform-api-tesserix-production",
        "serviceAccountRef": {"name": "platform-api-production-reader"},
    }
    sa = resource(docs, "ServiceAccount", "platform-api-production-reader")
    assert sa["metadata"]["namespace"] == "tesserix"
    assert sa["automountServiceAccountToken"] is False

    secret = resource(docs, "ExternalSecret", "platform-api-repos-github-app")
    assert secret["spec"]["secretStoreRef"] == {
        "name": "openbao-platform-api-production",
        "kind": "SecretStore",
    }
    assert {d["remoteRef"]["key"] for d in secret["spec"]["data"]} == PATHS
    assert {d["secretKey"] for d in secret["spec"]["data"]} == {
        "REPOS_GITHUB_APP_ID",
        "REPOS_GITHUB_APP_INSTALLATION_ID",
        "REPOS_GITHUB_APP_PRIVATE_KEY",
    }
