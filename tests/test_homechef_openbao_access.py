import json
import pathlib
import re
import subprocess

import yaml

ROOT = pathlib.Path(__file__).parents[1]


def render(chart):
    output = subprocess.run(
        ["helm", "template", "openbao", str(ROOT / chart), "--namespace", "openbao"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [doc for doc in yaml.safe_load_all(output) if doc]


def resource(documents, kind, name):
    return next(
        doc
        for doc in documents
        if doc["kind"] == kind and doc["metadata"]["name"] == name
    )


def test_legacy_api_role_cannot_read_bff_or_other_homechef_apps():
    documents = render("charts/thirdparty/openbao")
    config = resource(documents, "ConfigMap", "openbao-bootstrap")["data"]
    policy = config["policy-read-homechef.hcl"]
    assert re.findall(r'path "([^"]+)"', policy) == [
        "kv/data/homechef/homechef-api/*",
        "kv/metadata/homechef/homechef-api/*",
    ]
    assert 'capabilities = ["read"]' in policy
    role = json.loads(config["role-read-homechef.json"])
    assert role["bound_service_account_names"] == ["homechef-api"]
    assert role["bound_service_account_namespaces"] == ["homechef"]


def test_api_and_bff_stores_have_separate_persistent_read_only_roles():
    documents = render("charts/thirdparty/openbao")
    config = resource(documents, "ConfigMap", "openbao-bootstrap")["data"]
    for app in ("homechef-api", "homechef-auth-bff"):
        name = f"app-homechef_{app}"
        role = json.loads(config[f"role-{name}.json"])
        assert role["bound_service_account_names"] == [app]
        assert role["bound_service_account_namespaces"] == ["homechef"]
        assert role["token_policies"] == [name]
        policy = config[f"policy-{name}.hcl"]
        assert re.findall(r'path "([^"]+)"', policy) == [
            f"kv/data/homechef/{app}/*",
            f"kv/metadata/homechef/{app}/*",
        ]
        assert re.findall(r"capabilities = \[([^]]+)\]", policy) == [
            '"read"',
            '"read", "list"',
        ]
        store = resource(documents, "SecretStore", f"openbao-{app}")
        assert store["metadata"]["namespace"] == "homechef"
        auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
        assert auth["role"] == name
        assert auth["serviceAccountRef"] == {"name": app}


def test_only_api_and_worker_have_direct_openbao_network_access():
    documents = render("charts/apps/openbao-namespace")
    ingress = resource(documents, "NetworkPolicy", "allow-clients-to-openbao")["spec"][
        "ingress"
    ][0]
    homechef_sources = [
        source
        for source in ingress["from"]
        if source.get("namespaceSelector", {})
        .get("matchLabels", {})
        .get("kubernetes.io/metadata.name")
        == "homechef"
    ]
    assert homechef_sources == [
        {
            "namespaceSelector": {
                "matchLabels": {"kubernetes.io/metadata.name": "homechef"}
            },
            "podSelector": {"matchLabels": {"app.kubernetes.io/name": "homechef-api"}},
        }
    ]
    assert ingress["ports"] == [{"protocol": "TCP", "port": 8200}]
    auth = resource(documents, "AuthorizationPolicy", "allow-known-sources")
    principals = [
        principal
        for rule in auth["spec"]["rules"]
        for source in rule.get("from", [])
        for principal in source["source"].get("principals", [])
    ]
    assert "cluster.local/ns/homechef/sa/homechef-api" in principals
    assert "cluster.local/ns/homechef/sa/homechef-auth-bff" not in principals
    result = subprocess.run(
        ["kubectl", "kustomize", str(ROOT / "manifests/homechef-istio")],
        capture_output=True,
        text=True,
        check=True,
    )
    homechef = list(yaml.safe_load_all(result.stdout))
    egress = resource(
        homechef, "NetworkPolicy", "allow-homechef-api-to-openbao-egress"
    )["spec"]
    assert egress["podSelector"] == {
        "matchLabels": {"app.kubernetes.io/name": "homechef-api"}
    }
    assert egress["policyTypes"] == ["Egress"]
    assert egress["egress"] == [
        {
            "to": [
                {
                    "namespaceSelector": {
                        "matchLabels": {"kubernetes.io/metadata.name": "openbao"}
                    },
                    "podSelector": {
                        "matchLabels": {"app.kubernetes.io/name": "openbao"}
                    },
                }
            ],
            "ports": [{"protocol": "TCP", "port": 8200}],
        }
    ]
