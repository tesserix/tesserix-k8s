import json
import re

from test_homechef_openbao_access import render, resource

READERS = {
    "tesserix": ["bff-internal-hmac-key", "platform-admin-password"],
    "roamie": ["google-weather-api-key"],
    "support-platform": ["mcp-key", "support-hook-secret"],
    "agentgateway-system": ["mcp-key"],
    "db-backup-and-restore": ["postgresql-password"],
}


def test_cross_namespace_consumers_have_only_exact_read_paths():
    docs = render("charts/thirdparty/openbao")
    config = resource(docs, "ConfigMap", "openbao-bootstrap")["data"]
    for namespace, suffixes in READERS.items():
        role_name = "read-fe3dr-" + namespace
        policy = config["policy-" + role_name + ".hcl"]
        assert set(re.findall(r'path "([^"]+)"', policy)) == {
            "kv/data/homechef/homechef-api/fe3dr-" + suffix for suffix in suffixes
        }
        assert all(
            c.strip() == '"read"'
            for c in re.findall(r"capabilities = \[([^]]+)\]", policy)
        )
        role = json.loads(config["role-" + role_name + ".json"])
        assert role["bound_service_account_names"] == ["fe3dr-secret-reader"]
        assert role["bound_service_account_namespaces"] == [namespace]
        assert role["token_policies"] == [role_name]
        stores = [
            d
            for d in docs
            if d["kind"] == "SecretStore"
            and d["metadata"].get("namespace") == namespace
            and d["metadata"]["name"] == "openbao-fe3dr-shared"
        ]
        assert len(stores) == 1
        auth = stores[0]["spec"]["provider"]["vault"]["auth"]["kubernetes"]
        assert auth["role"] == role_name
        assert auth["serviceAccountRef"] == {"name": "fe3dr-secret-reader"}
        sa = next(
            d
            for d in docs
            if d["kind"] == "ServiceAccount"
            and d["metadata"].get("namespace") == namespace
            and d["metadata"]["name"] == "fe3dr-secret-reader"
        )
        assert sa["automountServiceAccountToken"] is False


def test_namespace_manifests_no_longer_reference_coordinated_gcp_sources():
    import pathlib
    import subprocess
    import yaml

    root = pathlib.Path(__file__).parents[1]
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(root / "external-secrets/prod")], text=True
            )
        )
    )
    old = {
        "prod-homechef-bff-internal-hmac-key",
        "prod-homechef-support-hook-secret",
        "prod-support-platform-homechef-mcp-key",
        "prod-homechef-platform-admin-password",
        "prod-homechef-postgresql-password",
    }
    switched = []
    for doc in docs:
        if not doc or doc.get("kind") != "ExternalSecret":
            continue
        for entry in doc["spec"].get("data", []):
            assert entry.get("remoteRef", {}).get("key") not in old
            if (
                entry.get("sourceRef", {}).get("storeRef", {}).get("name")
                == "openbao-fe3dr-shared"
            ):
                assert doc["metadata"]["namespace"] in READERS
                assert entry["remoteRef"]["property"] == "value"
                assert entry["remoteRef"]["key"].startswith(
                    "homechef/homechef-api/fe3dr-"
                )
                switched.append(entry)
    assert len(switched) == 5
