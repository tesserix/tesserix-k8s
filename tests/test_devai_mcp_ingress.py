import pathlib
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
                self.assertEqual(
                    [
                        {
                            "operation": {
                                "paths": ["/mcp/*"],
                                "methods": ["GET", "POST", "DELETE"],
                            }
                        }
                    ],
                    gateway_rule["to"],
                )


if __name__ == "__main__":
    unittest.main()
