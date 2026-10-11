import unittest
from test_kora_ai_gateway_manifests import render_chart, resource

class LedgerAttribution(unittest.TestCase):
    def test_gateway_captures_identity_and_non_openai_usage(self):
        docs = render_chart("charts/apps/kora-ai-gateway", "kora", "agentgateway-system")
        policy = resource(docs,"AgentgatewayPolicy","kora-ai-observability")
        attrs = {a["name"]: a["expression"] for a in policy["spec"]["frontend"]["tracing"]["attributes"]["add"]}
        for key in ["tesserix.user_id", "tesserix.service", "tesserix.decision_model", "tesserix.decision_input_tokens", "tesserix.decision_output_tokens"]:
            self.assertIn(key, attrs)
        gate = resource(docs,"HTTPRoute","kora-gate-decide")
        self.assertEqual('/internal/v1/decisions',gate['spec']['rules'][0]['matches'][0]['path']['value'])
        for name in ['kora-decide-traffic','kora-gate-decide-traffic']:
            traffic=resource(docs,'AgentgatewayPolicy',name)['spec']['traffic']
            self.assertNotIn('extProc',traffic)
            self.assertEqual(64000,traffic['buffer']['response']['maxBytes'])
            self.assertIn('jev_input',traffic['transformation']['response']['metadata'])

    def test_gate_workload_is_limited_to_private_decisions(self):
        docs = render_chart("charts/apps/kora-ai-gateway", "kora", "agentgateway-system")
        rules = resource(docs, "AuthorizationPolicy", "kora-ai")["spec"]["rules"]
        principal = "cluster.local/ns/agentgateway-system/sa/token-optimizer"
        gate_rules = [r for r in rules if any(principal in f["source"].get("principals", []) for f in r.get("from", []))]
        self.assertEqual(1, len(gate_rules))
        self.assertEqual(["/internal/v1/decisions"], gate_rules[0]["to"][0]["operation"]["paths"])
        self.assertEqual(["POST"], gate_rules[0]["to"][0]["operation"]["methods"])

    def test_processor_has_no_public_provider_egress(self):
        docs = render_chart("charts/apps/token-optimizer", "token-optimizer", "agentgateway-system")
        policy = resource(docs, "NetworkPolicy", "token-optimizer")
        for rule in policy["spec"]["egress"]:
            self.assertTrue(rule["to"])
            self.assertTrue(all("ipBlock" not in peer for peer in rule["to"]))
            self.assertNotIn(443, [port["port"] for port in rule["ports"]])
        deployment = resource(docs, "Deployment", "token-optimizer")
        env = {e["name"]: e for e in deployment["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertNotIn("TOKEN_OPTIMIZER_JEV_API_KEY", env)
        self.assertEqual("kora-ai-gateway-client-credentials", env["TOKEN_OPTIMIZER_GATEWAY_API_KEY"]["valueFrom"]["secretKeyRef"]["name"])

    def test_attribution_is_captured_before_provider_headers_are_removed(self):
        docs = render_chart("charts/apps/kora-ai-gateway", "kora", "agentgateway-system")
        for name in ["kora-ai-traffic", "kora-decide-traffic", "kora-gate-decide-traffic", "kora-a2a-user-auth"]:
            traffic = resource(docs, "AgentgatewayPolicy", name)["spec"]["traffic"]
            metadata = traffic.get("transformation", {}).get("request", {}).get("metadata", {})
            self.assertIn("ledger_user", metadata)
            self.assertIn("ledger_service", metadata)
            for key in ["agent_id", "agent_version", "agent_run_id"]:
                self.assertIn("ledger_" + key, metadata)
        policy = resource(docs, "AgentgatewayPolicy", "kora-ai-observability")
        attrs = {a["name"]: a["expression"] for a in policy["spec"]["frontend"]["tracing"]["attributes"]["add"]}
        self.assertIn("metadata.ledger_user", attrs["tesserix.user_id"])
        self.assertIn("metadata.ledger_service", attrs["tesserix.service"])

    def test_ledger_has_response_status_and_preserved_capability(self):
        docs = render_chart("charts/apps/kora-ai-gateway", "kora", "agentgateway-system")
        policy = resource(docs, "AgentgatewayPolicy", "kora-ai-observability")
        attrs = {a["name"]: a["expression"] for a in policy["spec"]["frontend"]["tracing"]["attributes"]["add"]}
        self.assertEqual("response.code", attrs.get("http.response.status_code"))
        self.assertIn("metadata.ledger_capability", attrs["tesserix.capability"])

    def test_decision_responses_are_json_readable_for_accounting(self):
        docs = render_chart("charts/apps/kora-ai-gateway", "kora", "agentgateway-system")
        for name in ["kora-decide", "kora-gate-decide"]:
            route = resource(docs, "HTTPRoute", name)
            header = next(f["requestHeaderModifier"] for f in route["spec"]["rules"][0]["filters"] if f["type"] == "RequestHeaderModifier")
            self.assertIn({"name": "Accept-Encoding", "value": "identity"}, header.get("set", []))

    def test_agent_details_are_exported_and_removed_before_provider_egress(self):
        docs = render_chart("charts/apps/kora-ai-gateway", "kora", "agentgateway-system")
        attrs = {a["name"]: a["expression"] for a in resource(docs, "AgentgatewayPolicy", "kora-ai-observability")["spec"]["frontend"]["tracing"]["attributes"]["add"]}
        ext = resource(docs, "AgentgatewayPolicy", "kora-ai-traffic")["spec"]["traffic"]["extProc"]["requestAttributes"]
        for key in ["agent_id", "agent_version", "agent_run_id"]:
            self.assertIn("metadata.ledger_" + key, attrs["tesserix." + key])
            self.assertIn("kora." + key, ext)
        for name in ["kora-ai", "kora-decide", "kora-gate-decide"]:
            for rule in resource(docs, "HTTPRoute", name)["spec"]["rules"]:
                modifiers = [f["requestHeaderModifier"] for f in rule.get("filters", []) if f["type"] == "RequestHeaderModifier"]
                self.assertTrue(modifiers)
                for header in ["X-Kora-Agent-Id", "X-Kora-Agent-Version", "X-Kora-Agent-Run-Id"]:
                    self.assertIn(header, modifiers[0].get("remove", []))
