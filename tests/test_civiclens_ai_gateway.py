import pathlib
import subprocess
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


def render(chart, namespace):
    output = subprocess.check_output(
        [
            "helm",
            "template",
            "test",
            str(ROOT / "charts/apps" / chart),
            "--namespace",
            namespace,
        ],
        text=True,
    )
    return [r for r in yaml.safe_load_all(output) if r]


class CivicLensAI(unittest.TestCase):
    def test_private_gateway_requires_key_and_scopes_model_route(self):
        resources = render("civiclens-ai-gateway", "agentgateway-system")
        route = next(r for r in resources if r["kind"] == "HTTPRoute")
        self.assertEqual(route["spec"]["parentRefs"][0]["name"], "civiclens-ai")
        self.assertEqual(
            route["spec"]["rules"][0]["matches"],
            [
                {
                    "path": {"type": "Exact", "value": "/v1/chat/completions"},
                    "method": "POST",
                }
            ],
        )
        policy = next(r for r in resources if r["kind"] == "AgentgatewayPolicy")
        self.assertEqual(
            policy["spec"]["traffic"]["apiKeyAuthentication"]["mode"], "Strict"
        )
        self.assertIn("rateLimit", policy["spec"]["traffic"])
        backend = next(r for r in resources if r["kind"] == "AgentgatewayBackend")
        provider = backend["spec"]["ai"]["groups"][0]["providers"][0]
        self.assertEqual(provider["vertexai"]["model"], "gemini-3.5-flash")
        self.assertEqual(provider["policies"]["auth"], {"gcp": {}})
        auth = next(r for r in resources if r["kind"] == "AuthorizationPolicy")
        self.assertEqual(
            auth["spec"]["rules"][0]["from"][0]["source"]["principals"],
            ["cluster.local/ns/civiclens/sa/civiclens-api"],
        )

    def test_key_is_generated_once_in_openbao_and_never_embedded(self):
        resources = render("civiclens-ai-gateway", "agentgateway-system")
        self.assertFalse(any(r["kind"] == "Secret" for r in resources))
        external = next(r for r in resources if r["kind"] == "ExternalSecret")
        self.assertEqual(
            external["spec"]["secretStoreRef"],
            {"kind": "SecretStore", "name": "openbao-civiclens-production"},
        )
        self.assertEqual(
            external["spec"]["data"][0]["remoteRef"]["key"],
            "civiclens/prod/app/civiclens-ai-gateway-key",
        )
        script = next(r for r in resources if r["kind"] == "ConfigMap")["data"][
            "seed.py"
        ]
        self.assertIn('"cas": 0', script)
        self.assertIn("secrets.token_hex(32)", script)
        self.assertIn("auth/token/revoke-self", script)

    def test_api_uses_same_key_and_private_gateway_with_publishing_off(self):
        resources = render("civiclens-api", "civiclens")
        deployment = next(r for r in resources if r["kind"] == "Deployment")
        env = {
            e["name"]: e.get("value")
            for e in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertEqual(
            env["CIVICLENS_AI_GATEWAY_URL"],
            "http://civiclens-ai.agentgateway-system.svc.cluster.local:8080",
        )
        self.assertEqual(env["CIVICLENS_PUBLISHING_ENABLED"], "false")
        secret = next(
            r
            for r in resources
            if r["kind"] == "ExternalSecret"
            and r["metadata"]["name"] == "civiclens-api-config"
        )
        self.assertIn(
            "civiclens-ai-gateway-key",
            secret["spec"]["target"]["template"]["data"]["secrets.json"],
        )
        self.assertIn("aiGatewayKey", [d["secretKey"] for d in secret["spec"]["data"]])


if __name__ == "__main__":
    unittest.main()
