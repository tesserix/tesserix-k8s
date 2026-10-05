import json
import pathlib
import unittest

import yaml

from test_kora_ai_gateway_manifests import render_chart, resource

ROOT = pathlib.Path(__file__).parents[1]


class JevGatewayTests(unittest.TestCase):
    def test_typed_decisions_use_authenticated_non_chat_route(self):
        docs = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        route = resource(docs, "HTTPRoute", "kora-decide")
        rule = route["spec"]["rules"][0]
        self.assertEqual(rule["matches"][0]["path"], {"type": "Exact", "value": "/v1/decisions"})
        self.assertEqual(rule["matches"][0]["method"], "POST")
        self.assertEqual(rule["backendRefs"][0]["name"], "kora-typesafe")
        removed = rule["filters"][1]["requestHeaderModifier"]["remove"]
        self.assertIn("X-Kora-End-User-Token", removed)
        self.assertIn("X-Kora-Delegated-End-User-Token", removed)
        backend = resource(docs, "AgentgatewayBackend", "kora-typesafe")["spec"]
        self.assertEqual(backend["static"], {"host": "api.typesafe.ai", "port": 443})
        self.assertNotIn("ai", backend)
        self.assertIn("tls", backend["policies"])
        self.assertEqual(backend["policies"]["auth"]["secretRef"], {"name": "kora-typesafe-credentials", "key": "api-key"})
        policy = resource(docs, "AgentgatewayPolicy", "kora-decide-traffic")["spec"]["traffic"]
        self.assertEqual(policy["apiKeyAuthentication"]["mode"], "Strict")
        self.assertEqual(policy["jwtAuthentication"]["mode"], "Strict")
        self.assertEqual(policy["timeouts"]["request"], "1500ms")
        self.assertNotIn("extProc", policy)
        self.assertIn("jev-1.13.0", policy["transformation"]["request"]["body"])
        self.assertIn("rateLimit", policy)

    def test_only_gateway_reader_gets_typesafe_secret_from_openbao(self):
        docs = render_chart("charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system")
        secret = resource(docs, "ExternalSecret", "kora-typesafe-credentials")["spec"]
        self.assertEqual(secret["secretStoreRef"], {"name": "openbao-kora-production", "kind": "SecretStore"})
        self.assertEqual(secret["data"], [{"secretKey": "api-key", "remoteRef": {"key": "kora/app/kora-typesafe-api-key", "property": "value"}}])
        values = yaml.safe_load((ROOT / "charts/thirdparty/openbao/values.yaml").read_text())
        policies = values["bootstrap"]["policies"]
        holders = [p["name"] for p in policies if 'kv/data/kora/app/kora-typesafe-api-key' in p["hcl"]]
        self.assertEqual(holders, ["read-kora-agentgateway-system-production"])

    def test_registry_bundle_contains_all_new_route_resources(self):
        bundle = json.loads((ROOT / "charts/apps/agentgateway-route-sync/files/platform-resources.json").read_text())
        for kind, name in [("HTTPRoute", "kora-decide"), ("AgentgatewayBackend", "kora-typesafe"), ("AgentgatewayPolicy", "kora-decide-traffic")]:
            resource(bundle["items"], kind, name)
        values = yaml.safe_load((ROOT / "charts/apps/agentgateway-route-sync/values.yaml").read_text())
        self.assertEqual(len(bundle["items"]), values["registryPlatformSeed"]["expectedCount"])
