import pathlib
import subprocess

import yaml


ROOT = pathlib.Path(__file__).parents[1]
GATEWAY_PRINCIPAL = "cluster.local/ns/agentgateway-system/sa/agentgateway-mcp"
ROUTER_PRINCIPAL = (
    "cluster.local/ns/support-platform/sa/support-platform-slm-router"
)
PRODUCTS = {
    "homechef": "homechef",
    "mark8ly": "mark8ly",
    "platform": "support-platform",
    "kora": "kora",
}


def render_chart(chart: str, release: str, namespace: str, *values: str) -> list[dict]:
    command = [
        "helm",
        "template",
        release,
        str(ROOT / chart),
        "--namespace",
        namespace,
    ]
    for value in values:
        command.extend(["--set", value])
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents: list[dict], kind: str, name: str) -> dict:
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


def test_each_product_mcp_has_a_dedicated_non_token_service_account() -> None:
    for tenant, namespace in PRODUCTS.items():
        documents = render_chart(
            "charts/apps/mcp-gateway",
            f"{tenant}-mcp",
            namespace,
            f"tenant={tenant}",
            f"namespace={namespace}",
        )
        service_account = resource(documents, "ServiceAccount", f"{tenant}-mcp")
        deployment = resource(documents, "Deployment", f"{tenant}-mcp")
        pod = deployment["spec"]["template"]["spec"]

        assert service_account["automountServiceAccountToken"] is False
        assert pod["serviceAccountName"] == f"{tenant}-mcp"
        assert pod["automountServiceAccountToken"] is False


def test_each_product_mcp_allows_only_the_two_trusted_spiffe_principals() -> None:
    for tenant, namespace in PRODUCTS.items():
        documents = render_chart(
            "charts/apps/mcp-gateway",
            f"{tenant}-mcp",
            namespace,
            f"tenant={tenant}",
            f"namespace={namespace}",
        )
        allow = resource(
            documents, "AuthorizationPolicy", f"{tenant}-mcp-allow-callers"
        )
        deny = resource(
            documents, "AuthorizationPolicy", f"{tenant}-mcp-deny-untrusted"
        )
        peer_authentication = resource(
            documents, "PeerAuthentication", f"{tenant}-mcp-strict-mtls"
        )
        expected_principals = [GATEWAY_PRINCIPAL, ROUTER_PRINCIPAL]

        assert allow["spec"]["selector"]["matchLabels"] == {
            "app.kubernetes.io/name": f"{tenant}-mcp"
        }
        assert allow["spec"]["rules"] == [
            {
                "from": [{"source": {"principals": expected_principals}}],
                "to": [{"operation": {"ports": ["8765"]}}],
            }
        ]
        assert deny["spec"]["action"] == "DENY"
        assert deny["spec"]["rules"] == [
            {
                "from": [{"source": {"notPrincipals": expected_principals}}],
                "to": [{"operation": {"ports": ["8765"]}}],
            }
        ]
        assert peer_authentication["spec"]["mtls"]["mode"] == "STRICT"


def test_mark8ly_is_ambient_enrolled() -> None:
    namespace_documents = render_chart(
        "charts/apps/mark8ly-namespace", "mark8ly-namespace", "mark8ly"
    )
    namespace = resource(namespace_documents, "Namespace", "mark8ly")
    assert namespace["metadata"]["labels"]["istio.io/dataplane-mode"] == "ambient"
    assert namespace["metadata"]["labels"]["istio.io/use-waypoint"] == "waypoint"


def test_mark8ly_does_not_broadly_trust_the_agentgateway_namespace() -> None:
    documents = render_chart(
        "charts/apps/mark8ly-namespace", "mark8ly-namespace", "mark8ly"
    )
    policy = resource(documents, "AuthorizationPolicy", "allow-known-sources")
    namespaces = policy["spec"]["rules"][0]["from"][0]["source"]["namespaces"]
    assert "agentgateway-system" not in namespaces
