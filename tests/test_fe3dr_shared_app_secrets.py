import json
import pathlib
import re
import subprocess

import yaml
from test_homechef_openbao_access import render, resource

ROOT = pathlib.Path(__file__).parents[1]
READERS = {
    "homechef": [
        "resend-api-key",
        "github-feedback-token",
        "support-platform-otto-internal-auth",
        "support-platform-postgres-username",
        "support-platform-postgres-password",
    ],
    "dwellm8": ["resend-api-key", "cashfree-test-app-id", "cashfree-test-secret-key"],
    "mark8ly": [
        "resend-api-key",
        "support-platform-otto-internal-auth",
        "support-platform-postgres-username",
        "support-platform-postgres-password",
    ],
    "support-platform": [
        "resend-api-key",
        "support-platform-otto-internal-auth",
        "support-platform-postgres-username",
        "support-platform-postgres-password",
    ],
    "tesserix": ["resend-api-key", "support-platform-otto-internal-auth"],
    "stockpilot": [
        "support-platform-postgres-username",
        "support-platform-postgres-password",
    ],
}


def test_shared_readers_are_exact_read_only_and_namespace_bound():
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
    for ns, suffixes in READERS.items():
        name = "read-fe3dr-appdeps-" + ns
        policy = config["policy-" + name + ".hcl"]
        assert set(re.findall(r'path "([^"]+)"', policy)) == {
            "kv/data/homechef/homechef-api/fe3dr-" + s for s in suffixes
        }
        assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}
        role = json.loads(config["role-" + name + ".json"])
        assert role["bound_service_account_namespaces"] == [ns]
        assert role["bound_service_account_names"] == ["fe3dr-appdeps-reader"]
        store = next(
            d
            for d in docs
            if d
            and d["kind"] == "SecretStore"
            and d["metadata"]["name"] == "openbao-fe3dr-appdeps"
            and d["metadata"]["namespace"] == ns
        )
        assert store["spec"]["provider"]["vault"]["auth"]["kubernetes"]["role"] == name


def test_declared_shared_consumers_use_canonical_openbao_values():
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    count = 0
    for d in docs:
        if not d or d["kind"] != "ExternalSecret":
            continue
        for entry in d["spec"].get("data", []):
            key = entry["remoteRef"]["key"]
            assert key not in {
                "prod-resend-api-key",
                "prod-support-platform-otto-internal-auth",
                "prod-support-platform-postgres-username",
                "prod-support-platform-postgres-password",
            }
            if (
                entry.get("sourceRef", {}).get("storeRef", {}).get("name")
                == "openbao-fe3dr-appdeps"
            ):
                ns = d["metadata"]["namespace"]
                assert key in {"homechef/homechef-api/fe3dr-" + s for s in READERS[ns]}
                assert entry["remoteRef"]["property"] == "value"
                count += 1
    assert count == 9
