import unittest

from test_kora_ai_gateway_manifests import ROOT, load_yaml, render_chart, resource


INGEST_CHART = "charts/apps/ai-usage-ingest"
GATEWAY_CHART = "charts/apps/kora-ai-gateway"


class AIUsageIngestManifestTests(unittest.TestCase):
    """The export path from the gateway to the console's cost ledger.

    Every assertion here is about a hop that fails silently when it is wrong:
    a missing ReferenceGrant, a NetworkPolicy that omits one side, or a sampled
    trace all leave a running gateway and a ledger that quietly stops filling.
    """

    def setUp(self):
        self.ingest = render_chart(INGEST_CHART, "ai-usage-ingest", "tesserix")
        self.gateway = render_chart(GATEWAY_CHART, "kora-ai-gateway", "agentgateway-system")
        self.tracing = resource(
            self.gateway, "AgentgatewayPolicy", "kora-ai-observability"
        )["spec"]["frontend"]["tracing"]

    def test_the_gateway_exports_to_the_ingest_service(self):
        self.assertEqual("HTTP", self.tracing["protocol"])
        self.assertEqual("/v1/traces", self.tracing["path"])

        backend = self.tracing["backendRef"]
        service = resource(self.ingest, "Service", "ai-usage-ingest")
        self.assertEqual("Service", backend["kind"])
        self.assertEqual(service["metadata"]["name"], backend["name"])
        self.assertEqual(service["metadata"]["namespace"], backend["namespace"])
        self.assertEqual(service["spec"]["ports"][0]["port"], backend["port"])

    def test_every_request_is_traced(self):
        # A sampled ledger is not a bill.
        self.assertEqual("1.0", self.tracing["clientSampling"])
        self.assertEqual("1.0", self.tracing["randomSampling"])

    def test_the_gateway_attributes_its_own_spend(self):
        # The gateway cannot learn the product from the request, and a
        # client-supplied header cannot be trusted with the answer.
        added = {a["name"]: a["expression"] for a in self.tracing["attributes"]["add"]}
        self.assertEqual("'kora'", added["tesserix.product"])
        self.assertEqual("'kora-ai'", added["tesserix.gateway"])
        self.assertIn("x-kora-ai-capability", added["tesserix.capability"])

    def test_the_cross_namespace_reference_is_granted(self):
        grant = resource(
            self.ingest, "ReferenceGrant", "allow-agentgateway-system-ai-usage-otlp"
        )
        self.assertEqual("tesserix", grant["metadata"]["namespace"])
        self.assertEqual(
            {"group": "agentgateway.dev", "kind": "AgentgatewayPolicy",
             "namespace": "agentgateway-system"},
            grant["spec"]["from"][0],
        )
        # Scoped to the one Service: a namespace-wide grant would let any future
        # policy there address anything in tesserix.
        self.assertEqual("ai-usage-ingest", grant["spec"]["to"][0]["name"])

    def test_both_ends_of_the_export_are_permitted_by_network_policy(self):
        egress = resource(
            self.gateway, "NetworkPolicy", "kora-ai"
        )["spec"]["egress"]
        to_ingest = [
            rule
            for rule in egress
            if any(
                peer.get("podSelector", {}).get("matchLabels", {}).get(
                    "app.kubernetes.io/name"
                )
                == "ai-usage-ingest"
                for peer in rule.get("to", [])
            )
        ]
        self.assertEqual(1, len(to_ingest), "the gateway may not reach the ingest")
        self.assertEqual(4318, to_ingest[0]["ports"][0]["port"])

        ingress = resource(
            self.ingest, "NetworkPolicy", "allow-ai-usage-ingest-otlp"
        )["spec"]["ingress"]
        sources = {
            peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
            for rule in ingress
            for peer in rule["to" if "to" in rule else "from"]
        }
        self.assertEqual({"agentgateway-system"}, sources)

    def test_the_ingest_may_reach_nats_and_postgres(self):
        # `allow-company-egress` in this namespace uses podSelector: {} and names
        # neither, so without this policy the writer connects to nothing.
        egress = resource(
            self.ingest, "NetworkPolicy", "allow-ai-usage-ingest-egress"
        )["spec"]["egress"]
        reachable = {
            (
                peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"],
                port["port"],
            )
            for rule in egress
            for peer in rule["to"]
            for port in rule["ports"]
        }
        self.assertIn(("nats", 4222), reachable)
        self.assertIn(("tesserix", 5432), reachable)
        self.assertIn(("kube-system", 53), reachable)

    def test_the_ingest_runs_the_ingest_binary_from_the_platform_api_image(self):
        deployment = resource(self.ingest, "Deployment", "ai-usage-ingest")
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        self.assertTrue(container["image"].endswith("tesserix-platform-api:latest"))
        self.assertEqual(["/app/ai-usage-ingest"], container["command"])

        env = {entry["name"]: entry for entry in container["env"]}
        self.assertEqual(":4318", env["AI_USAGE_INGEST_ADDR"]["value"])
        self.assertIn("nats.nats.svc.cluster.local", env["AI_USAGE_NATS_URL"]["value"])
        # The same database the console and the platform API read.
        self.assertEqual("tesserix_admin", env["TESSERIX_DB_NAME"]["value"])
        self.assertEqual(
            "tesserix-postgres-tesserix-admin",
            env["TESSERIX_DB_PASSWORD"]["valueFrom"]["secretKeyRef"]["name"],
        )

    def test_the_ingest_has_no_readiness_gate_on_the_stream(self):
        # A NATS blip must not take the export endpoint out of the Service, or
        # the gateway loses the spend that blip caused.
        container = resource(self.ingest, "Deployment", "ai-usage-ingest")[
            "spec"]["template"]["spec"]["containers"][0]
        self.assertNotIn("readinessProbe", container)
        self.assertEqual("/healthz", container["livenessProbe"]["httpGet"]["path"])

    def test_argocd_owns_the_ingest_in_the_console_s_namespace(self):
        application = load_yaml(ROOT / "argocd/prod/apps/global/ai-usage-ingest.yaml")[0]
        self.assertEqual("tesserix", application["spec"]["destination"]["namespace"])
        self.assertEqual(INGEST_CHART, application["spec"]["source"]["path"])

        kustomization = load_yaml(ROOT / "argocd/prod/apps/global/kustomization.yaml")[0]
        self.assertIn("ai-usage-ingest.yaml", kustomization["resources"])


if __name__ == "__main__":
    unittest.main()
