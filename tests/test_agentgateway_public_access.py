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
    command = [
        "helm",
        "template",
        "test",
        str(ROOT / chart),
        "--namespace",
        "agentgateway-system",
    ]
    if chart in {
        "charts/apps/agentgateway-route-sync",
        "charts/apps/devai-ai-gateway",
    }:
        command.extend(["--set", "registryOwnership.enabled=false"])
    result = subprocess.run(
        command,
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
    def test_exact_hosts_split_machine_apis_from_browser_uis(self):
        documents = render_agentic_istio()
        expected = {
            "mcp-agentgateway": (
                "mcp.tesserix.app",
                "/mcp",
                "agentgateway-mcp.agentgateway-system.svc.cluster.local",
                "mcp-gateway-ui-oauth2-proxy.agentgateway-system.svc.cluster.local",
                4180,
            ),
            "solo-agentgateway": (
                "agentgateway.tesserix.app",
                "/openai",
                "ai-gateway.agentgateway-system.svc.cluster.local",
                "agentgateway-console.agentgateway-system.svc.cluster.local",
                8082,
            ),
        }

        for name, (host, api_prefix, backend, ui_backend, ui_port) in expected.items():
            virtual_service = resource(documents, "VirtualService", name)
            self.assertEqual([host], virtual_service["spec"]["hosts"])
            self.assertEqual(
                ["istio-ingress/tesseract-gateway"],
                virtual_service["spec"]["gateways"],
            )
            api_route = next(
                route
                for route in virtual_service["spec"]["http"]
                if any(
                    match.get("uri", {}).get("exact") == api_prefix
                    or match.get("uri", {}).get("prefix") == f"{api_prefix}/"
                    for match in route.get("match", [])
                )
            )["route"][0]["destination"]
            self.assertEqual(backend, api_route["host"])
            self.assertEqual(8081, api_route["port"]["number"])
            self.assertNotEqual(
                "agentgateway.agentgateway-system.svc.cluster.local",
                api_route["host"],
            )
            browser_route = virtual_service["spec"]["http"][-1]["route"][0][
                "destination"
            ]
            self.assertEqual(ui_backend, browser_route["host"])
            self.assertEqual(ui_port, browser_route["port"]["number"])
            if name == "solo-agentgateway":
                self.assertFalse(
                    any(
                        "redirect" in route
                        for route in virtual_service["spec"]["http"]
                    )
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
        self.assertEqual(
            '"agentgateway.mcp" in jwt["urn:zitadel:iam:org:project:386889024519799084:roles"]',
            expressions[0],
        )
        self.assertEqual("Allow", authorization["action"])

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
        self.assertEqual(
            '"agentgateway.models" in jwt["urn:zitadel:iam:org:project:386889024519799084:roles"]',
            expressions[0],
        )
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
            .get("notPorts") == ["8080", "8081", "15000"]
        )
        self.assertEqual(
            {"notPorts": ["8080", "8081", "15000"]},
            non_data_plane_rule["to"][0]["operation"],
        )

    def test_mcp_browser_ui_uses_isolated_zitadel_oauth_proxy(self):
        documents = render_chart("charts/apps/agentgateway-route-sync")
        name = "mcp-gateway-ui-oauth2-proxy"
        deployment = resource(documents, "Deployment", name)
        service = resource(documents, "Service", name)
        external_secret = resource(documents, "ExternalSecret", name)
        emails = resource(documents, "ConfigMap", f"{name}-emails")
        pdb = resource(documents, "PodDisruptionBudget", name)
        network_policy = resource(documents, "NetworkPolicy", name)

        self.assertEqual(2, deployment["spec"]["replicas"])
        self.assertEqual(1, pdb["spec"]["minAvailable"])
        self.assertEqual("ClusterIP", service["spec"]["type"])
        self.assertEqual(4180, service["spec"]["ports"][0]["port"])
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        self.assertIn("@sha256:", container["image"])
        self.assertIn("--provider=oidc", container["args"])
        self.assertIn(f"--oidc-issuer-url={ISSUER}", container["args"])
        self.assertIn(
            "--redirect-url=https://mcp.tesserix.app/oauth2/callback",
            container["args"],
        )
        self.assertIn(
            "--upstream=http://agentregistry.agentregistry-system.svc.cluster.local:12121",
            container["args"],
        )
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(
            HUMAN_EMAILS,
            set(emails["data"]["authenticated-emails.txt"].splitlines()),
        )
        remote_keys = {
            item["remoteRef"]["key"] for item in external_secret["spec"]["data"]
        }
        self.assertEqual(
            {
                "prod-agentgateway-mcp-ui-client-id",
                "prod-agentgateway-mcp-ui-client-secret",
                "prod-agentgateway-mcp-ui-cookie-secret",
            },
            remote_keys,
        )
        self.assertEqual(["Ingress", "Egress"], network_policy["spec"]["policyTypes"])

    def test_mcp_ui_seeds_the_released_registry_image(self):
        application = yaml.safe_load(
            (ROOT / "argocd/prod/apps/ai-apps/agentic-registry.yaml").read_text()
        )
        parameters = {
            item["name"]: item["value"]
            for item in application["spec"]["source"]["helm"]["parameters"]
        }
        self.assertEqual("v0.1.0", parameters["image.tag"])

    def test_solo_admin_ui_is_private_and_uses_isolated_zitadel_oauth_proxy(self):
        documents = render_chart("charts/apps/devai-ai-gateway")
        name = "agentgateway-admin-ui-oauth2-proxy"
        parameters = resource(documents, "AgentgatewayParameters", "ai-gateway")
        admin_service = resource(documents, "Service", "ai-gateway-admin")
        deployment = resource(documents, "Deployment", name)
        service = resource(documents, "Service", name)
        external_secret = resource(documents, "ExternalSecret", name)

        generated_container = parameters["spec"]["deployment"]["spec"]["template"][
            "spec"
        ]["containers"][0]
        self.assertEqual("agentgateway", generated_container["name"])
        generated_env = {
            item["name"]: item["value"] for item in generated_container["env"]
        }
        self.assertEqual("0.0.0.0:15000", generated_env["ADMIN_ADDR"])

        self.assertEqual("ClusterIP", admin_service["spec"]["type"])
        self.assertEqual(
            {"port": 15000, "targetPort": 15000},
            {
                "port": admin_service["spec"]["ports"][0]["port"],
                "targetPort": admin_service["spec"]["ports"][0]["targetPort"],
            },
        )
        self.assertEqual(
            {"gateway.networking.k8s.io/gateway-name": "ai-gateway"},
            admin_service["spec"]["selector"],
        )

        self.assertEqual(2, deployment["spec"]["replicas"])
        self.assertEqual("ClusterIP", service["spec"]["type"])
        args = deployment["spec"]["template"]["spec"]["containers"][0]["args"]
        self.assertIn(f"--oidc-issuer-url={ISSUER}", args)
        self.assertIn(
            "--redirect-url=https://agentgateway.tesserix.app/oauth2/callback",
            args,
        )
        self.assertEqual(
            {
                "--upstream=http://agentregistry.agentregistry-system.svc.cluster.local:12121/",
                "--upstream=http://ai-gateway-admin.agentgateway-system.svc.cluster.local:15000/ui/",
                "--upstream=http://ai-gateway-admin.agentgateway-system.svc.cluster.local:15000/api/",
                "--upstream=http://ai-gateway-admin.agentgateway-system.svc.cluster.local:15000/config_dump",
            },
            {argument for argument in args if argument.startswith("--upstream=")},
        )
        self.assertIn("--pass-access-token=true", args)
        self.assertIn("--pass-authorization-header=true", args)
        self.assertIn(
            "--backend-logout-url=https://auth.tesserix.app/oidc/v1/end_session?id_token_hint={id_token}",
            args,
        )
        remote_keys = {
            item["remoteRef"]["key"] for item in external_secret["spec"]["data"]
        }
        self.assertEqual(
            {
                "prod-agentgateway-admin-ui-client-id",
                "prod-agentgateway-admin-ui-client-secret",
                "prod-agentgateway-admin-ui-cookie-secret",
            },
            remote_keys,
        )

        istio_policy = resource(documents, "AuthorizationPolicy", "ai-gateway")
        admin_rule = next(
            rule
            for rule in istio_policy["spec"]["rules"]
            if rule.get("to", [{}])[0].get("operation", {}).get("ports")
            == ["15000"]
        )
        self.assertEqual(
            [
                "cluster.local/ns/agentgateway-system/sa/agentgateway-admin-ui-oauth2-proxy"
            ],
            admin_rule["from"][0]["source"]["principals"],
        )

        sanitizer = resource(
            documents, "VirtualService", "ai-gateway-admin-sanitize-auth-headers"
        )
        self.assertEqual(
            ["ai-gateway-admin.agentgateway-system.svc.cluster.local"],
            sanitizer["spec"]["hosts"],
        )
        self.assertEqual(["mesh"], sanitizer["spec"]["gateways"])
        self.assertEqual(
            ["authorization", "cookie", "x-forwarded-access-token"],
            sanitizer["spec"]["http"][0]["headers"]["request"]["remove"],
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
        config_mount = next(
            mount for mount in container["volumeMounts"] if mount["name"] == "config"
        )
        self.assertEqual(
            "/data/ratelimit/config/config.yaml", config_mount["mountPath"]
        )
        self.assertEqual("config.yaml", config_mount["subPath"])
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
