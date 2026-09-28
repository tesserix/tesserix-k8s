import json
import re
import subprocess

import yaml
from test_homechef_openbao_access import ROOT, render, resource

OPENPANEL = {
    f"prod-openpanel-{suffix}": f"openpanel/app/openpanel-{suffix}"
    for suffix in (
        "admin-email",
        "admin-password",
        "cookie-secret",
        "db-password",
        "oauth2-client-id",
        "oauth2-client-secret",
        "oauth2-cookie-secret",
        "root-client-id",
        "root-client-secret",
    )
}
CLIENTS = {
    f"prod-openpanel-{product}-client-id": f"{product}/app/{product}-openpanel-client-id"
    for product in ("devai", "langfuse")
}
TARGETS = OPENPANEL | CLIENTS


def test_openpanel_access_is_exact_and_namespace_bound():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for name, sa, namespace, paths, caps in (
        (
            "read-openpanel-production",
            "openpanel-production-reader",
            "openpanel",
            set(OPENPANEL.values()),
            ["read"],
        ),
        (
            "read-openpanel-analytics-production",
            "openpanel-production-reader",
            "analytics-operator",
            {
                OPENPANEL[f"prod-openpanel-root-client-{suffix}"]
                for suffix in ("id", "secret")
            },
            ["read"],
        ),
        (
            "analytics-onboarding-writer",
            "analytics-onboarding-operator",
            "analytics-operator",
            set(CLIENTS.values()),
            ["create", "read", "update"],
        ),
    ):
        role = json.loads(config[f"role-{name}.json"])
        assert role["bound_service_account_names"] == [sa]
        assert role["bound_service_account_namespaces"] == [namespace]
        assert role["token_ttl"] in ("5m", "15m")
        policy = config[f"policy-{name}.hcl"]
        assert "*" not in policy
        assert set(re.findall(r'path "kv/data/([^\"]+)"', policy)) == paths
        for line in policy.splitlines():
            if 'path "kv/data/' in line:
                assert f"capabilities = {json.dumps(caps)}" in line
    assert (
        json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
            "openpanel"
        ]
        == TARGETS
    )


def test_openpanel_reader_stores_and_writer_egress():
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    for namespace, role in (
        ("openpanel", "read-openpanel-production"),
        ("analytics-operator", "read-openpanel-analytics-production"),
    ):
        store = next(
            d
            for d in docs
            if d["kind"] == "SecretStore"
            and d["metadata"]["name"] == "openbao-openpanel-production"
            and d["metadata"]["namespace"] == namespace
        )
        assert store["spec"]["provider"]["vault"]["auth"]["kubernetes"] == {
            "mountPath": "kubernetes",
            "role": role,
            "serviceAccountRef": {"name": "openpanel-production-reader"},
        }
    operator = list(
        yaml.safe_load_all(
            (ROOT / "k8s/operators/analytics-onboarding/resources.yaml").read_text()
        )
    )
    policy = resource(operator, "NetworkPolicy", "analytics-onboarding-operator")
    assert any(
        peer.get("namespaceSelector", {})
        .get("matchLabels", {})
        .get("kubernetes.io/metadata.name")
        == "openbao"
        and peer.get("podSelector", {})
        .get("matchLabels", {})
        .get("app.kubernetes.io/name")
        == "openbao"
        and {"protocol": "TCP", "port": 8200} in rule.get("ports", [])
        for rule in policy["spec"]["egress"]
        for peer in rule.get("to", [])
    )


def test_openbao_accepts_only_analytics_operator_identity():
    documents = render("charts/apps/openbao-namespace")
    policy = resource(documents, "NetworkPolicy", "allow-clients-to-openbao")
    sources = [
        peer
        for rule in policy["spec"]["ingress"]
        for peer in rule.get("from", [])
        if peer.get("namespaceSelector", {})
        .get("matchLabels", {})
        .get("kubernetes.io/metadata.name")
        == "analytics-operator"
    ]
    assert sources == [
        {
            "namespaceSelector": {
                "matchLabels": {"kubernetes.io/metadata.name": "analytics-operator"}
            },
            "podSelector": {
                "matchLabels": {
                    "app.kubernetes.io/name": "analytics-onboarding-operator"
                }
            },
        }
    ]
    auth = resource(documents, "AuthorizationPolicy", "allow-known-sources")
    assert any(
        "cluster.local/ns/analytics-operator/sa/analytics-onboarding-operator"
        in source.get("source", {}).get("principals", [])
        for rule in auth["spec"]["rules"]
        for source in rule.get("from", [])
    )


def test_openpanel_temporary_migration_writer_is_retired():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    assert "role-openpanel-migrate-reviewed.json" not in config
    assert "policy-openpanel-migrate-reviewed.hcl" not in config
    docs = list(
        yaml.safe_load_all(
            (ROOT / "external-secrets/prod/openpanel-openbao-readers.yaml").read_text()
        )
    )
    assert all(doc["metadata"]["name"] != "openpanel-migration-writer" for doc in docs)
