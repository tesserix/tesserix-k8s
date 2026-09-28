import json
import re

import yaml
from test_homechef_openbao_access import ROOT, render, resource

MAPPING = {
    "prod-obs-api-session-secret": "observability-session-secret",
    "prod-obs-api-google-client-id": "observability-google-client-id",
    "prod-obs-api-google-client-secret": "observability-google-client-secret",
    "prod-obs-github-app-id": "observability-github-app-id",
    "prod-obs-github-app-installation-id": "observability-github-app-installation-id",
    "prod-obs-github-app-private-key": "observability-github-app-private-key",
}


def test_observability_reader_is_exact_read_only_and_namespace_bound():
    cm = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    role = json.loads(cm["role-read-observability-production.json"])
    assert role["bound_service_account_names"] == ["observability-production-reader"]
    assert role["bound_service_account_namespaces"] == ["observability"]
    policy = cm["policy-read-observability-production.hcl"]
    assert "*" not in policy
    assert set(re.findall(r'path "kv/data/([^\"]+)"', policy)) == {
        "observability/app/" + v for v in MAPPING.values()
    }
    assert all(
        'capabilities = ["read"]' in line
        for line in policy.splitlines()
        if 'path "kv/data/' in line
    )
    assert json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
        "observability"
    ] == {k: "observability/app/" + v for k, v in MAPPING.items()}


def test_observability_preserves_all_six_application_keys():
    es = yaml.safe_load(
        (ROOT / "external-secrets/prod/observability/obs-api-secrets.yaml").read_text()
    )
    assert es["spec"]["secretStoreRef"] == {
        "name": "openbao-observability-production",
        "kind": "SecretStore",
    }
    assert es["spec"]["refreshInterval"] == "5m"
    assert {x["secretKey"] for x in es["spec"]["data"]} == {
        "session-secret",
        "google-client-id",
        "google-client-secret",
        "github-app-id",
        "github-installation-id",
        "github-app-key.pem",
    }
    assert {x["remoteRef"]["key"] for x in es["spec"]["data"]} == {
        "observability/app/" + v for v in MAPPING.values()
    }
    assert all(x["remoteRef"]["property"] == "value" for x in es["spec"]["data"])
