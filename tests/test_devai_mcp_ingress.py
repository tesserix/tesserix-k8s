import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
GATEWAY_PRINCIPAL = (
    "cluster.local/ns/agentgateway-system/sa/agentgateway-mcp"
)
GATEWAY_PEER = {
    "namespaceSelector": {
        "matchLabels": {
            "kubernetes.io/metadata.name": "agentgateway-system",
        }
    },
    "podSelector": {
        "matchLabels": {
            "gateway.networking.k8s.io/gateway-name": "agentgateway-mcp",
        }
    },
}


def load_documents(name):
    path = ROOT / "manifests/devai-istio" / name
    return [document for document in yaml.safe_load_all(path.read_text()) if document]


def resource(documents, kind, name):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


def render_chart(chart, release, namespace):
    result = subprocess.run(
        [
            "helm",
            "template",
            release,
            str(ROOT / chart),
            "--namespace",
            namespace,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


class DevAIMCPIngressTests(unittest.TestCase):
    def test_agentgateway_brokers_the_existing_devai_service_token(self):
        external_secrets = [
            document
            for document in yaml.safe_load_all(
                (
                    ROOT
                    / "external-secrets/prod/agentgateway-system/externalsecret.yaml"
                ).read_text()
            )
            if document
        ]
        external_secret = resource(
            external_secrets, "ExternalSecret", "devai-mcp-upstream"
        )

        self.assertEqual(
            {
                "name": "devai-mcp-upstream",
                "creationPolicy": "Owner",
            },
            external_secret["spec"]["target"],
        )
        self.assertEqual(
            [
                {
                    "secretKey": "token",
                    "remoteRef": {"key": "prod-devai-mcp-hub-service-token"},
                }
            ],
            external_secret["spec"]["data"],
        )

    def test_agentgateway_mcp_can_reach_devai_mcp_endpoints(self):
        network_policies = load_documents("network-policy.yaml")
        authorization_policies = load_documents("authorization-policy.yaml")

        for workload, port in (("devai-api", 8080), ("devai-sre", 8090)):
            with self.subTest(workload=workload):
                network_policy = resource(
                    network_policies, "NetworkPolicy", f"{workload}-netpol"
                )
                gateway_ingress = next(
                    rule
                    for rule in network_policy["spec"]["ingress"]
                    if GATEWAY_PEER in rule.get("from", [])
                )
                self.assertEqual(
                    {(port, "TCP"), (15008, "TCP")},
                    {
                        (entry["port"], entry["protocol"])
                        for entry in gateway_ingress["ports"]
                    },
                )

                authorization_policy = resource(
                    authorization_policies,
                    "AuthorizationPolicy",
                    f"{workload}-authz",
                )
                gateway_rule = next(
                    rule
                    for rule in authorization_policy["spec"]["rules"]
                    if any(
                        GATEWAY_PRINCIPAL
                        in source.get("source", {}).get("principals", [])
                        for source in rule.get("from", [])
                    )
                )
                ambient_gateway_rule = next(
                    rule
                    for rule in authorization_policy["spec"]["rules"]
                    if any(
                        source.get("source", {}).get("namespaces")
                        == ["agentgateway-system"]
                        for source in rule.get("from", [])
                    )
                )
                if workload == "devai-api":
                    self.assertNotIn("to", gateway_rule)
                    self.assertNotIn("to", ambient_gateway_rule)
                else:
                    expected_operation = [
                        {
                            "operation": {
                                "paths": ["/mcp/*"],
                                "methods": ["GET", "POST", "DELETE"],
                            }
                        }
                    ]
                    self.assertEqual(expected_operation, gateway_rule["to"])
                    self.assertEqual(expected_operation, ambient_gateway_rule["to"])

    def test_agentgateway_mcp_has_ambient_egress_to_devai(self):
        policies = [
            document
            for document in yaml.safe_load_all(
                (
                    ROOT
                    / "manifests/agentic-istio/networkpolicy-consumer-egress.yaml"
                ).read_text()
            )
            if document
        ]
        policy = resource(
            policies,
            "NetworkPolicy",
            "allow-agentgateway-mcp-to-devai-egress",
        )

        self.assertEqual(
            {
                "gateway.networking.k8s.io/gateway-name": "agentgateway-mcp",
            },
            policy["spec"]["podSelector"]["matchLabels"],
        )
        self.assertEqual(["Egress"], policy["spec"]["policyTypes"])
        self.assertEqual(
            [
                {
                    "to": [
                        {
                            "namespaceSelector": {
                                "matchLabels": {
                                    "kubernetes.io/metadata.name": "devai",
                                }
                            }
                        }
                    ]
                }
            ],
            policy["spec"]["egress"],
        )

    def test_agentgateway_mcp_can_reach_registered_product_backends(self):
        policies = [
            document
            for document in yaml.safe_load_all(
                (
                    ROOT / "manifests/agentic-istio/networkpolicy-consumer-egress.yaml"
                ).read_text()
            )
            if document
        ]
        egress = resource(
            policies,
            "NetworkPolicy",
            "allow-agentgateway-mcp-to-product-mcp-egress",
        )
        destinations = {
            peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
            for rule in egress["spec"]["egress"]
            for peer in rule["to"]
        }
        self.assertEqual(
            {"homechef", "mark8ly", "stockpilot", "support-platform"}, destinations
        )

        homechef = render_chart(
            "charts/thirdparty/istio-config", "istio-config", "istio-system"
        )
        homechef_policy = resource(homechef, "NetworkPolicy", "allow-homechef-ingress")
        homechef_sources = {
            peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
            for rule in homechef_policy["spec"]["ingress"]
            for peer in rule["from"]
        }
        self.assertIn("agentgateway-system", homechef_sources)

        support = render_chart(
            "charts/apps/support-platform-namespace",
            "support-platform-namespace",
            "support-platform",
        )
        support_policy = resource(
            support, "NetworkPolicy", "allow-in-namespace-and-sources"
        )
        support_sources = {
            peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
            for rule in support_policy["spec"]["ingress"]
            for peer in rule["from"]
            if "namespaceSelector" in peer
            and "kubernetes.io/metadata.name"
            in peer["namespaceSelector"].get("matchLabels", {})
        }
        self.assertIn("agentgateway-system", support_sources)

        mark8ly = render_chart(
            "charts/apps/mark8ly-namespace", "mark8ly-namespace", "mark8ly"
        )
        mark8ly_policy = resource(mark8ly, "AuthorizationPolicy", "allow-known-sources")
        mark8ly_sources = set(
            mark8ly_policy["spec"]["rules"][0]["from"][0]["source"]["namespaces"]
        )
        self.assertIn("agentgateway-system", mark8ly_sources)

        stockpilot = render_chart(
            "charts/thirdparty/istio-config", "istio-config", "istio-system"
        )
        stockpilot_policy = resource(
            stockpilot, "NetworkPolicy", "allow-stockpilot-ingress"
        )
        stockpilot_sources = {
            peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
            for rule in stockpilot_policy["spec"]["ingress"]
            for peer in rule["from"]
        }
        self.assertIn("agentgateway-system", stockpilot_sources)

    def test_devai_services_are_discoverable_as_identity_aware_mcp_targets(self):
        cases = (
            (
                "charts/apps/devai-api",
                {
                    "analyst-mcp": "/mcp/analyst",
                    "devai-mcp": "/mcp/devai",
                    "gitops-mcp": "/mcp/gitops/",
                    "sample-mcp": "/mcp/sample/",
                    "scm-mcp": "/mcp/scm/",
                },
            ),
            ("charts/apps/devai-sre", {"sre-mcp": "/mcp/sre"}),
        )

        for chart, services in cases:
            documents = render_chart(chart, "devai-mcp", "devai")
            for name, path in services.items():
                with self.subTest(service=name):
                    service = resource(documents, "Service", name)
                    self.assertEqual(
                        name,
                        service["metadata"]["labels"][
                            "mcp.tesserix.app/server"
                        ],
                    )
                    self.assertEqual(
                        "none",
                        service["metadata"]["labels"]["istio.io/use-waypoint"],
                    )
                    self.assertEqual(
                        path,
                        service["metadata"]["annotations"][
                            "agentgateway.dev/mcp-path"
                        ],
                    )
                    self.assertEqual(
                        name,
                        service["metadata"]["annotations"][
                            "agentgateway.dev/mcp-target-name"
                        ],
                    )
                    self.assertEqual(
                        "agentgateway.dev/mcp",
                        service["spec"]["ports"][0]["appProtocol"],
                    )


if __name__ == "__main__":
    unittest.main()
