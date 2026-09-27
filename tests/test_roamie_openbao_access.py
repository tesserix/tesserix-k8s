import json
import pathlib
import re
import subprocess

import yaml
from test_homechef_openbao_access import render, resource

ROOT = pathlib.Path(__file__).parents[1]
READERS = {
    "agentgateway-system-production": ["agents-api-key", "travel-mcp-key"],
    "agentregistry-system-production": ["registry-deploy-key-sha256"],
    "document-intelligence-production": [
        "api-ocr-key",
        "document-intelligence-db-password",
    ],
    "document-intelligence-development": ["api-ocr-key"],
    "global-production": ["document-intelligence-db-password"],
    "roamie-production": [
        "agents-api-key",
        "agents-gateway-clients",
        "api-ocr-key",
        "api-places-key",
        "delegation-key",
        "manager-api-key",
        "manager-gateway-clients",
        "manager-identity-key",
        "manager-subject",
        "mcp-api-token",
        "mcp-delegated-token",
        "postgresql-password",
        "postgresql-runtime-password",
        "profile-signing-key",
        "travel-mcp-key",
    ],
}


def test_roamie_readers_are_exact_read_only_and_environment_bound():
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
    for key, suffixes in READERS.items():
        namespace, environment = key.rsplit("-", 1)
        role_name = "read-roamie-" + key
        role = json.loads(config["role-" + role_name + ".json"])
        account = "roamie-" + environment + "-reader"
        assert role["bound_service_account_namespaces"] == [namespace]
        assert role["bound_service_account_names"] == [account]
        assert role["token_policies"] == [role_name]
        prefix = "roamie-development" if environment == "development" else "roamie"
        policy = config["policy-" + role_name + ".hcl"]
        assert set(re.findall(r'path "([^"]+)"', policy)) == {
            "kv/data/" + prefix + "/app/roamie-" + suffix for suffix in suffixes
        }
        assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}
        store = next(
            d
            for d in docs
            if d
            and d["kind"] == "SecretStore"
            and d["metadata"]["namespace"] == namespace
            and d["metadata"]["name"] == "openbao-roamie-" + environment
        )
        auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
        assert auth["role"] == role_name
        assert auth["serviceAccountRef"] == {"name": account}
