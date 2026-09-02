from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]


def render_istio_config():
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "istio-config",
            str(ROOT / "charts/thirdparty/istio-config"),
            "--namespace",
            "istio-system",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [document for document in yaml.safe_load_all(rendered) if document]


def resource(documents, kind, name):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


def test_analytics_operator_can_reach_openpanel_api():
    documents = render_istio_config()
    network_policy = resource(documents, "NetworkPolicy", "allow-ingress-to-openpanel")
    allowed_namespaces = {
        peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
        for rule in network_policy["spec"]["ingress"]
        for peer in rule.get("from", [])
        if "namespaceSelector" in peer
    }
    assert "analytics-operator" in allowed_namespaces

    authorization_policy = resource(
        documents, "AuthorizationPolicy", "allow-ingress-to-openpanel"
    )
    authorized_namespaces = {
        namespace
        for rule in authorization_policy["spec"]["rules"]
        for source in rule.get("from", [])
        for namespace in source.get("source", {}).get("namespaces", [])
    }
    assert "analytics-operator" in authorized_namespaces


def test_analytics_operator_allows_ambient_hbone_egress():
    resources = list(
        yaml.safe_load_all(
            (ROOT / "k8s/operators/analytics-onboarding/resources.yaml").read_text()
        )
    )
    network_policy = resource(
        resources, "NetworkPolicy", "analytics-onboarding-operator"
    )
    hbone_rule = next(
        rule
        for rule in network_policy["spec"]["egress"]
        if {port["port"] for port in rule.get("ports", [])} == {15008}
    )

    assert hbone_rule["to"] == [{"ipBlock": {"cidr": "10.20.0.0/16"}}]


def test_analytics_operator_can_reach_node_local_dns():
    resources = list(
        yaml.safe_load_all(
            (ROOT / "k8s/operators/analytics-onboarding/resources.yaml").read_text()
        )
    )
    network_policy = resource(
        resources, "NetworkPolicy", "analytics-onboarding-operator"
    )
    dns_rule = next(
        rule
        for rule in network_policy["spec"]["egress"]
        if rule.get("to") == [{"ipBlock": {"cidr": "10.30.0.10/32"}}]
    )

    assert {
        (port.get("protocol", "TCP"), port["port"])
        for port in dns_rule["ports"]
    } == {("TCP", 53), ("UDP", 53)}
