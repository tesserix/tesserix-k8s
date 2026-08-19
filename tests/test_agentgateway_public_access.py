import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
ISSUER = "https://auth.tesserix.app"
JWKS_PATH = "/oauth/v2/keys"
PROJECT_AUDIENCE = "386889024519799084"
HUMAN_EMAILS = {"samyak.rout@gmail.com", "mahesh.sangawar@gmail.com"}


def render_chart(chart):
    result = subprocess.run(
        [
            "helm",
            "template",
            "test",
            str(ROOT / chart),
            "--namespace",
            "agentgateway-system",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def render_agentic_istio():
    result = subprocess.run(
        ["kubectl", "kustomize", str(ROOT / "manifests/agentic-istio")],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def render_istio_auth_policies():
    application = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/istio-auth-policies.yaml").read_text()
    )
    chart = ROOT / "charts/infrastructure/istio-auth-policies"
    result = subprocess.run(
        [
            "helm",
            "template",
            "test",
            str(chart),
            "--namespace",
            "istio-system",
            "--values",
            str(chart / "values.yaml"),
            "--values",
            str(chart / "values-prod.yaml"),
            "--values",
            "-",
        ],
        input=application["spec"]["source"]["helm"]["values"],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents, kind, name):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


def public_policy(documents, name):
    policy = resource(documents, "AgentgatewayPolicy", name)
    jwt = policy["spec"]["traffic"]["jwtAuthentication"]
    authorization = policy["spec"]["traffic"]["authorization"]
    rate_limit = policy["spec"]["traffic"]["rateLimit"]["global"]
    return policy, jwt, authorization, rate_limit


class AgentGatewayPublicAccessTests(unittest.TestCase):
    def test_exact_hosts_route_to_distinct_data_planes(self):
        documents = render_agentic_istio()
        expected = {
            "mcp-agentgateway": (
                "mcp.tesserix.app",
                "agentgateway-mcp.agentgateway-system.svc.cluster.local",
            ),
            "solo-agentgateway": (
                "agentgateway.tesserix.app",
                "ai-gateway.agentgateway-system.svc.cluster.local",
            ),
        }

        for name, (host, backend) in expected.items():
            virtual_service = resource(documents, "VirtualService", name)
            self.assertEqual([host], virtual_service["spec"]["hosts"])
            self.assertEqual(
                ["istio-ingress/tesseract-gateway"],
                virtual_service["spec"]["gateways"],
            )
            route = virtual_service["spec"]["http"][0]["route"][0]["destination"]
            self.assertEqual(backend, route["host"])
            self.assertEqual(8081, route["port"]["number"])
            self.assertNotEqual(
                "agentgateway.agentgateway-system.svc.cluster.local",
                route["host"],
            )

    def test_mcp_gateway_is_private_hardened_and_disruption_safe(self):
        documents = render_chart("charts/apps/agentgateway-route-sync")
        parameters = resource(
            documents, "AgentgatewayParameters", "agentgateway-mcp"
        )
        gateway = resource(documents, "Gateway", "agentgateway-mcp")

        self.assertEqual(
            {
                "group": "agentgateway.dev",
                "kind": "AgentgatewayParameters",
                "name": "agentgateway-mcp",
            },
            gateway["spec"]["infrastructure"]["parametersRef"],
        )
        self.assertEqual("ClusterIP", parameters["spec"]["service"]["spec"]["type"])
        self.assertEqual(2, parameters["spec"]["deployment"]["spec"]["replicas"])
        self.assertEqual(
            1,
            parameters["spec"]["podDisruptionBudget"]["spec"]["minAvailable"],
        )
        self.assertTrue(
            parameters["spec"]["deployment"]["spec"]["template"]["spec"]
            ["securityContext"]["runAsNonRoot"]
        )
        self.assertEqual(
            {"memory": "128Mi"}, parameters["spec"]["resources"]["requests"]
        )
        listeners = {
            listener["name"]: listener["port"]
            for listener in gateway["spec"]["listeners"]
        }
        self.assertEqual({"mcp": 8080, "public": 8081}, listeners)

    def test_mcp_gateway_requires_zitadel_identity_and_subject_rate_limit(self):
        documents = render_chart("charts/apps/agentgateway-route-sync")
        policy, jwt, authorization, rate_limit = public_policy(
            documents, "mcp-public-oauth"
        )

        self.assertEqual("Strict", jwt["mode"])
        provider = jwt["providers"][0]
        self.assertEqual(ISSUER, provider["issuer"])
        self.assertEqual([PROJECT_AUDIENCE], provider["audiences"])
        remote = provider["jwks"]["remote"]
        self.assertEqual(JWKS_PATH, remote["jwksPath"])
        self.assertEqual("mcp-zitadel-jwks", remote["backendRef"]["name"])

        expressions = authorization["policy"]["matchExpressions"]
        self.assertEqual(1, len(expressions))
        self.assertTrue(expressions[0].startswith('"agentgateway.mcp" in jwt['))
        self.assertEqual("Allow", authorization["action"])
        for email in HUMAN_EMAILS:
            self.assertIn(email, expressions[0])
        self.assertGreaterEqual(expressions[0].count(" || "), 2)

        self.assertEqual("agentgateway-ratelimit", rate_limit["backendRef"]["name"])
        self.assertEqual("FailClosed", rate_limit["failureMode"])
        descriptor = next(
            entry
            for item in rate_limit["descriptors"]
            for entry in item["entries"]
            if entry["name"] == "oauth_subject"
        )
        self.assertEqual("oauth_subject", descriptor["name"])
        self.assertEqual("jwt.sub", descriptor["expression"])
        self.assertEqual(
            "agentgateway-mcp", policy["spec"]["targetRefs"][0]["name"]
        )
        self.assertEqual("public", policy["spec"]["targetRefs"][0]["sectionName"])

    def test_solo_gateway_requires_zitadel_identity_and_subject_rate_limit(self):
        documents = render_chart("charts/apps/devai-ai-gateway")
        policy, jwt, authorization, rate_limit = public_policy(
            documents, "ai-public-oauth"
        )

        self.assertEqual("Strict", jwt["mode"])
        provider = jwt["providers"][0]
        self.assertEqual(ISSUER, provider["issuer"])
        self.assertEqual([PROJECT_AUDIENCE], provider["audiences"])
        self.assertEqual(
            "ai-zitadel-jwks",
            provider["jwks"]["remote"]["backendRef"]["name"],
        )
        expressions = authorization["policy"]["matchExpressions"]
        self.assertEqual(1, len(expressions))
        self.assertTrue(expressions[0].startswith('"agentgateway.models" in jwt['))
        for email in HUMAN_EMAILS:
            self.assertIn(email, expressions[0])
        self.assertGreaterEqual(expressions[0].count(" || "), 2)
        self.assertEqual("agentgateway-ratelimit", rate_limit["backendRef"]["name"])
        self.assertEqual("FailClosed", rate_limit["failureMode"])
        subject = next(
            entry
            for item in rate_limit["descriptors"]
            for entry in item["entries"]
            if entry["name"] == "oauth_subject"
        )
        self.assertEqual("jwt.sub", subject["expression"])
        self.assertEqual("ai-gateway", policy["spec"]["targetRefs"][0]["name"])
        self.assertEqual("public", policy["spec"]["targetRefs"][0]["sectionName"])

        gateway = resource(documents, "Gateway", "ai-gateway")
        listeners = {
            listener["name"]: listener["port"]
            for listener in gateway["spec"]["listeners"]
        }
        self.assertEqual({"http": 8080, "public": 8081}, listeners)
        route = resource(documents, "HTTPRoute", "devai-ai")
        self.assertEqual(
            {"http", "public"},
            {parent["sectionName"] for parent in route["spec"]["parentRefs"]},
        )
        istio_policy = resource(documents, "AuthorizationPolicy", "ai-gateway")
        public_rule = next(
            rule
            for rule in istio_policy["spec"]["rules"]
            if rule.get("to", [{}])[0].get("operation", {}).get("ports") == ["8081"]
        )
        self.assertEqual(
            ["cluster.local/ns/istio-ingress/sa/istio-ingressgateway"],
            public_rule["from"][0]["source"]["principals"],
        )
        non_data_plane_rule = next(
            rule
            for rule in istio_policy["spec"]["rules"]
            if rule.get("to", [{}])[0]
            .get("operation", {})
            .get("notPorts") == ["8080", "8081"]
        )
        self.assertEqual(
            {"notPorts": ["8080", "8081"]},
            non_data_plane_rule["to"][0]["operation"],
        )

    def test_public_gateway_access_logs_verified_subject_without_tokens(self):
        for chart, name in (
            ("charts/apps/agentgateway-route-sync", "mcp-public-observability"),
            ("charts/apps/devai-ai-gateway", "ai-public-observability"),
        ):
            documents = render_chart(chart)
            policy = resource(documents, "AgentgatewayPolicy", name)
            self.assertEqual(
                "public", policy["spec"]["targetRefs"][0]["sectionName"]
            )
            attributes = policy["spec"]["frontend"]["accessLog"]["attributes"]["add"]
            actual = {item["name"]: item["expression"] for item in attributes}
            self.assertEqual("jwt.sub", actual["auth.subject"])
            self.assertEqual("jwt.client_id", actual["auth.client_id"])
            self.assertNotIn("request.headers[\"authorization\"]", actual.values())

    def test_rate_limit_service_is_ha_private_and_uses_scoped_valkey_identity(self):
        documents = render_agentic_istio()
        deployment = resource(documents, "Deployment", "agentgateway-ratelimit")
        service = resource(documents, "Service", "agentgateway-ratelimit")
        pdb = resource(documents, "PodDisruptionBudget", "agentgateway-ratelimit")
        network_policy = resource(
            documents, "NetworkPolicy", "agentgateway-ratelimit"
        )
        config = resource(documents, "ConfigMap", "agentgateway-ratelimit")

        self.assertEqual(2, deployment["spec"]["replicas"])
        self.assertEqual("ClusterIP", service["spec"]["type"])
        self.assertEqual(1, pdb["spec"]["minAvailable"])
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        self.assertIn("@sha256:", container["image"])
        env = {item["name"]: item["value"] for item in container["env"]}
        self.assertEqual("agentgateway:nopass", env["REDIS_AUTH"])
        self.assertEqual("agentgateway:", env["CACHE_KEY_PREFIX"])
        self.assertEqual(
            "global-valkey-cache.global.svc.cluster.local:6379",
            env["REDIS_URL"],
        )
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(["Ingress", "Egress"], network_policy["spec"]["policyTypes"])
        self.assertIn("key: oauth_subject", config["data"]["config.yaml"])

    def test_ingress_accepts_only_agentgateway_audience_on_exact_hosts(self):
        application = yaml.safe_load(
            (ROOT / "argocd/prod/infrastructure/istio-auth-policies.yaml").read_text()
        )
        values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
        issuer = next(
            item for item in values["extraGip"] if item["issuer"] == ISSUER
        )
        self.assertEqual([PROJECT_AUDIENCE], issuer["audiences"])
        self.assertEqual(
            ["mcp.tesserix.app", "agentgateway.tesserix.app"],
            issuer["restrictToHosts"],
        )

        public_hosts = {
            host
            for app in values["frontendApps"]
            for host in app.get("hosts", [])
        }
        self.assertTrue(
            {"mcp.tesserix.app", "agentgateway.tesserix.app"}.issubset(public_hosts)
        )

        documents = render_istio_auth_policies()
        for suffix in ("", "-custom"):
            deny = resource(
                documents,
                "AuthorizationPolicy",
                f"deny-foreign-hosts-gip-agentgateway-zitadel{suffix}",
            )
            operation = deny["spec"]["rules"][0]["to"][0]["operation"]
            self.assertEqual(["80", "443"], operation["ports"])
            self.assertEqual(
                ["mcp.tesserix.app", "agentgateway.tesserix.app"],
                operation["notHosts"],
            )

    def test_valkey_isolates_agentgateway_rate_limit_keys(self):
        values = yaml.safe_load(
            (ROOT / "charts/apps/global-valkey/values-cache.yaml").read_text()
        )
        users = {item["name"]: item["prefix"] for item in values["acl"]["users"]}
        self.assertEqual("agentgateway", users["agentgateway"])
        self.assertIn(
            "agentgateway-system", values["networkPolicy"]["allowedNamespaces"]
        )


if __name__ == "__main__":
    unittest.main()
