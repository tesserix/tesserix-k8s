import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]


def load_yaml(path):
    return list(yaml.safe_load_all(path.read_text()))


def render_chart(chart, release, namespace, values=None):
    command = [
        "helm",
        "template",
        release,
        str(ROOT / chart),
        "--namespace",
        namespace,
    ]
    # Registry owns these CRs in production; the Helm rendering is the tested
    # rollback path, so it is what these assertions have to read.
    if chart in ("charts/apps/kora-ai-gateway", "charts/apps/devai-ai-gateway"):
        command.extend(["--set", "registryOwnership.enabled=false"])
    if values:
        command.extend(["--values", str(ROOT / chart / values)])
    result = subprocess.run(
        command,
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


class KoraAIGatewayManifestTests(unittest.TestCase):
    def test_workloads_share_the_isolated_agentgateway_namespace(self):
        for filename in ("kora-ai-gateway.yaml", "token-optimizer.yaml"):
            application = load_yaml(ROOT / "argocd/prod/apps/kora" / filename)[0]
            self.assertEqual(
                "agentgateway-system",
                application["spec"]["destination"]["namespace"],
            )
            self.assertEqual("infrastructure", application["spec"]["project"])

        agents = load_yaml(
            ROOT / "argocd/prod/apps/kora/kora-ai-agents.yaml"
        )[0]
        self.assertEqual("kora", agents["spec"]["destination"]["namespace"])
        self.assertEqual("infrastructure", agents["spec"]["project"])

    def test_gateway_uses_existing_vertex_identity_and_private_name(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        parameters = resource(documents, "AgentgatewayParameters", "kora-ai")
        gateway = resource(documents, "Gateway", "kora-ai")

        annotations = parameters["spec"]["serviceAccount"]["metadata"]["annotations"]
        self.assertEqual(
            "agentgateway-llm@tesseracthub-480811.iam.gserviceaccount.com",
            annotations["iam.gke.io/gcp-service-account"],
        )
        container = parameters["spec"]["deployment"]["spec"]["template"]["spec"][
            "containers"
        ][0]
        env = {entry["name"]: entry["value"] for entry in container["env"]}
        self.assertEqual("agentgateway", container["name"])
        self.assertEqual("169.254.169.254", env["GCE_METADATA_HOST"])
        self.assertEqual(
            "none",
            parameters["spec"]["service"]["metadata"]["labels"][
                "istio.io/use-waypoint"
            ],
        )
        self.assertEqual("agentgateway", gateway["spec"]["gatewayClassName"])

    def test_vertex_api_key_is_synchronized_but_workload_identity_authenticates(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        provider_secret = resource(
            documents,
            "ExternalSecret",
            "kora-ai-gateway-provider-credentials",
        )
        secret_data = {
            entry["secretKey"]: entry["remoteRef"]["key"]
            for entry in provider_secret["spec"]["data"]
        }
        self.assertEqual(
            "prod-kora-vertex-api-key", secret_data["vertex-api-key"]
        )

        backends = [
            document
            for document in documents
            if document.get("kind") == "AgentgatewayBackend"
            and "ai" in document.get("spec", {})
        ]
        for backend in backends:
            vertex = next(
                provider
                for group in backend["spec"]["ai"]["groups"]
                for provider in group["providers"]
                if provider["name"] == "vertex"
            )
            auth = vertex["policies"]["auth"]
            self.assertNotIn("host", vertex)
            self.assertNotIn("port", vertex)
            self.assertEqual({}, vertex["policies"]["tls"])
            self.assertEqual({}, auth["gcp"])
            self.assertNotIn("credentials", auth)

    def test_gateway_route_declares_kubernetes_default_values(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        route = resource(documents, "HTTPRoute", "kora-ai")

        self.assertEqual(
            {
                "group": "gateway.networking.k8s.io",
                "kind": "Gateway",
                "name": "kora-ai",
                "sectionName": "http",
            },
            route["spec"]["parentRefs"][0],
        )
        for rule in route["spec"]["rules"]:
            self.assertEqual(1, rule["backendRefs"][0]["weight"])
            for match in rule["matches"]:
                self.assertEqual(
                    {"type": "PathPrefix", "value": "/"}, match["path"]
                )

    def test_gateway_owns_vertex_models_and_routes_by_capability(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        route = resource(documents, "HTTPRoute", "kora-ai")
        embedding = resource(
            documents, "AgentgatewayBackend", "kora-embedding-providers"
        )
        structured = resource(
            documents, "AgentgatewayBackend", "kora-structured-providers"
        )
        conversation = resource(
            documents, "AgentgatewayBackend", "kora-conversation-providers"
        )

        embedding_rule = route["spec"]["rules"][0]
        self.assertEqual(
            {
                "name": "x-kora-ai-capability",
                "type": "Exact",
                "value": "embedding",
            },
            embedding_rule["matches"][0]["headers"][0],
        )
        self.assertEqual(
            "kora-embedding-providers",
            embedding_rule["backendRefs"][0]["name"],
        )

        embedding_vertex = embedding["spec"]["ai"]["groups"][0]["providers"][0]
        self.assertEqual("gemini-embedding-001", embedding_vertex["vertexai"]["model"])
        self.assertEqual("global", embedding_vertex["vertexai"]["region"])

        for backend in (structured, conversation):
            vertex = backend["spec"]["ai"]["groups"][0]["providers"][0]
            self.assertEqual("vertex", vertex["name"])
            self.assertEqual("gemini-3.5-flash", vertex["vertexai"]["model"])
            self.assertEqual("global", vertex["vertexai"]["region"])

        expected_routes = {
            "/v1/chat/completions": "Completions",
            "/v1/embeddings": "Embeddings",
            "*": "Detect",
        }
        for backend in (embedding, structured, conversation):
            self.assertEqual(
                expected_routes,
                backend["spec"]["policies"]["ai"]["routes"],
            )

        traffic = resource(documents, "AgentgatewayPolicy", "kora-ai-guardrails")
        self.assertNotIn("routes", traffic["spec"]["backend"]["ai"])

    def test_vertex_terraform_binds_the_kora_gateway_identity(self):
        main = (ROOT / "terraform-new/stacks/12-vertex/main.tf").read_text()
        variables = (ROOT / "terraform-new/stacks/12-vertex/variables.tf").read_text()
        production = (
            ROOT / "terraform-new/environments/prod/terraform.tfvars"
        ).read_text()

        self.assertIn(
            'resource "google_service_account_iam_member" "kora_agentgateway_wi"',
            main,
        )
        self.assertIn("variable \"kora_agentgateway_ksa\"", variables)
        self.assertIn(
            'kora_agentgateway_ksa   = "agentgateway-system/kora-ai"',
            production,
        )

    def test_gateway_does_not_require_a_missing_xai_credential(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        provider_secret = resource(
            documents,
            "ExternalSecret",
            "kora-ai-gateway-provider-credentials",
        )
        remote_refs = {
            entry["remoteRef"]["key"] for entry in provider_secret["spec"]["data"]
        }
        self.assertIn("prod-devai-anthropic-api-key", remote_refs)
        self.assertNotIn("prod-kora-xai-api-key", remote_refs)

        backends = [
            document
            for document in documents
            if document.get("kind") == "AgentgatewayBackend"
            and "ai" in document.get("spec", {})
        ]
        provider_names = {
            provider["name"]
            for backend in backends
            for group in backend["spec"]["ai"]["groups"]
            for provider in group["providers"]
        }
        self.assertNotIn("xai", provider_names)

    def test_gateway_only_accepts_kora_clients(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        policy = resource(documents, "NetworkPolicy", "kora-ai")
        api_client = policy["spec"]["ingress"][0]["from"][0]

        self.assertEqual(
            "kora",
            api_client["namespaceSelector"]["matchLabels"][
                "kubernetes.io/metadata.name"
            ],
        )
        self.assertEqual(
            "kora-api",
            api_client["podSelector"]["matchLabels"]["app.kubernetes.io/name"],
        )
        agent_client = policy["spec"]["ingress"][1]["from"][0]
        self.assertEqual(
            "kora-ai-agents",
            agent_client["podSelector"]["matchLabels"]["app.kubernetes.io/name"],
        )

    def test_gateway_listener_requires_workload_and_verified_app_user_identity(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        policy = resource(documents, "AuthorizationPolicy", "kora-ai")
        authentication = resource(documents, "RequestAuthentication", "kora-ai-user")

        selector = {
            "matchLabels": {
                "gateway.networking.k8s.io/gateway-name": "kora-ai"
            }
        }
        self.assertEqual(selector, policy["spec"]["selector"])
        self.assertEqual(selector, authentication["spec"]["selector"])
        self.assertNotIn("targetRefs", policy["spec"])
        self.assertNotIn("targetRefs", authentication["spec"])

        rule = authentication["spec"]["jwtRules"][0]
        self.assertEqual(
            "https://securetoken.google.com/kora-app-e6d38",
            rule["issuer"],
        )
        self.assertEqual(["kora-app-e6d38"], rule["audiences"])
        self.assertEqual(
            [{"name": "X-Kora-End-User-Token", "prefix": "Bearer "}],
            rule["fromHeaders"],
        )
        self.assertTrue(rule["forwardOriginalToken"])

        client_rule = policy["spec"]["rules"][0]
        self.assertEqual(
            ["cluster.local/ns/kora/sa/kora-api"],
            client_rule["from"][0]["source"]["principals"],
        )
        self.assertEqual(
            ["https://securetoken.google.com/kora-app-e6d38/*"],
            client_rule["from"][0]["source"]["requestPrincipals"],
        )
        self.assertEqual(["8080"], client_rule["to"][0]["operation"]["ports"])

        self.assertEqual(
            ["cluster.local/ns/kora/sa/kora-ai-agents"],
            policy["spec"]["rules"][1]["from"][0]["source"]["principals"],
        )
        self.assertEqual(
            ["https://securetoken.google.com/kora-app-e6d38/*"],
            policy["spec"]["rules"][1]["from"][0]["source"]["requestPrincipals"],
        )

        embedding_rule = policy["spec"]["rules"][2]
        self.assertEqual(
            ["cluster.local/ns/kora/sa/kora-api"],
            embedding_rule["from"][0]["source"]["principals"],
        )
        self.assertEqual(
            ["POST"], embedding_rule["to"][0]["operation"]["methods"]
        )
        self.assertEqual(
            ["/v1/embeddings"], embedding_rule["to"][0]["operation"]["paths"]
        )

    def test_model_routes_strip_the_delegated_identity_before_provider_egress(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        model_route = resource(documents, "HTTPRoute", "kora-ai")

        for rule in model_route["spec"]["rules"]:
            self.assertEqual(
                [
                    {
                        "type": "RequestHeaderModifier",
                        "requestHeaderModifier": {
                            "remove": ["X-Kora-End-User-Token"]
                        },
                    }
                ],
                rule.get("filters"),
            )

        a2a_route = resource(documents, "HTTPRoute", "kora-a2a")
        self.assertNotIn("filters", a2a_route["spec"]["rules"][0])

    def test_native_gateway_validates_user_jwt_on_user_scoped_routes(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        route = resource(documents, "HTTPRoute", "kora-ai")
        backend = resource(documents, "AgentgatewayBackend", "kora-firebase-jwks")
        policy = resource(documents, "AgentgatewayPolicy", "kora-user-auth")

        self.assertEqual(
            ["embedding", "conversation", "structured", "default"],
            [rule["name"] for rule in route["spec"]["rules"]],
        )
        self.assertEqual(
            {"host": "www.googleapis.com", "port": 443},
            backend["spec"]["static"],
        )
        self.assertEqual({}, backend["spec"]["policies"]["tls"])
        self.assertEqual(
            [
                {
                    "group": "gateway.networking.k8s.io",
                    "kind": "HTTPRoute",
                    "name": "kora-ai",
                    "sectionName": "conversation",
                },
                {
                    "group": "gateway.networking.k8s.io",
                    "kind": "HTTPRoute",
                    "name": "kora-ai",
                    "sectionName": "structured",
                },
                {
                    "group": "gateway.networking.k8s.io",
                    "kind": "HTTPRoute",
                    "name": "kora-ai",
                    "sectionName": "default",
                },
                {
                    "group": "gateway.networking.k8s.io",
                    "kind": "HTTPRoute",
                    "name": "kora-a2a",
                },
            ],
            policy["spec"]["targetRefs"],
        )
        jwt = policy["spec"]["traffic"]["jwtAuthentication"]
        self.assertEqual("Strict", jwt["mode"])
        self.assertEqual(
            {
                "header": {
                    "name": "X-Kora-End-User-Token",
                    "prefix": "Bearer ",
                }
            },
            jwt["location"],
        )
        provider = jwt["providers"][0]
        self.assertEqual(
            "https://securetoken.google.com/kora-app-e6d38",
            provider["issuer"],
        )
        self.assertEqual(["kora-app-e6d38"], provider["audiences"])
        self.assertEqual(
            "/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com",
            provider["jwks"]["remote"]["jwksPath"],
        )
        self.assertEqual(
            "kora-firebase-jwks",
            provider["jwks"]["remote"]["backendRef"]["name"],
        )

    def test_gateway_routes_a2a_and_owns_upstream_authentication(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        backend = resource(documents, "AgentgatewayBackend", "kora-a2a-agents")
        route = resource(documents, "HTTPRoute", "kora-a2a")
        policy = resource(documents, "AgentgatewayPolicy", "kora-a2a-traffic")
        secret = resource(
            documents,
            "ExternalSecret",
            "kora-ai-gateway-agent-credentials",
        )

        self.assertEqual(
            {
                "host": "kora-ai-agents.kora.svc.cluster.local",
                "port": 8080,
            },
            backend["spec"]["a2a"],
        )
        self.assertEqual("/a2a/v1/", route["spec"]["rules"][0]["matches"][0]["path"]["value"])
        self.assertEqual("kora-ai", route["spec"]["parentRefs"][0]["name"])
        self.assertEqual(
            "kora-a2a-agents",
            route["spec"]["rules"][0]["backendRefs"][0]["name"],
        )

        traffic = policy["spec"]["traffic"]
        self.assertEqual("Strict", traffic["apiKeyAuthentication"]["mode"])
        self.assertEqual({"request": "70s"}, traffic["timeouts"])
        self.assertEqual(
            "kora-ai-gateway-client-credentials",
            traffic["apiKeyAuthentication"]["secretRef"]["name"],
        )
        backend_auth = policy["spec"]["backend"]["auth"]
        self.assertEqual(
            {"name": "kora-ai-gateway-agent-credentials", "key": "API_KEY"},
            backend_auth["secretRef"],
        )
        self.assertEqual(
            {"name": "Authorization", "prefix": "Bearer "},
            backend_auth["location"]["header"],
        )
        self.assertEqual(
            "prod-kora-ai-agents-api-key",
            secret["spec"]["data"][0]["remoteRef"]["key"],
        )

        gateway_network = resource(documents, "NetworkPolicy", "kora-ai")
        agent_egress = next(
            rule
            for rule in gateway_network["spec"]["egress"]
            if rule.get("to", [{}])[0]
            .get("namespaceSelector", {})
            .get("matchLabels", {})
            .get("kubernetes.io/metadata.name")
            == "kora"
        )
        self.assertEqual(
            {
                "namespaceSelector": {
                    "matchLabels": {"kubernetes.io/metadata.name": "kora"}
                }
            },
            agent_egress["to"][0],
        )
        self.assertNotIn("ports", agent_egress)

    def test_optimizer_rtk_attribute_is_safe_when_the_optional_header_is_absent(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        policy = resource(documents, "AgentgatewayPolicy", "kora-ai-traffic")

        expression = policy["spec"]["traffic"]["extProc"]["requestAttributes"][
            "token_optimizer.rtk_applied"
        ]
        self.assertEqual(
            '"x-kora-rtk-applied" in request.headers ? '
            'request.headers["x-kora-rtk-applied"] == "true" : false',
            expression,
        )

    def test_kora_gets_only_a_client_key_and_narrow_gateway_egress(self):
        documents = render_chart(
            "charts/apps/kora-api", "kora", "kora", "values-prod.yaml"
        )
        deployment = resource(documents, "Deployment", "kora-kora-api")
        external_secret = resource(
            documents, "ExternalSecret", "kora-ai-gateway-client-credentials"
        )
        network_policy = resource(documents, "NetworkPolicy", "kora-ai-gateway-egress")

        env = {
            entry["name"]: entry
            for entry in deployment["spec"]["template"]["spec"]["containers"][0][
                "env"
            ]
        }
        self.assertEqual(
            "http://kora-ai.agentgateway-system.svc.cluster.local:8080/v1",
            env["AI_GATEWAY_BASE_URL"]["value"],
        )
        self.assertEqual(
            "prod-kora-ai-gateway-api-key",
            external_secret["spec"]["data"][0]["remoteRef"]["key"],
        )

        egress = network_policy["spec"]["egress"][0]
        destination = egress["to"][0]
        self.assertEqual(
            "agentgateway-system",
            destination["namespaceSelector"]["matchLabels"]
            ["kubernetes.io/metadata.name"],
        )
        self.assertEqual(8080, egress["ports"][0]["port"])

    def test_production_kora_api_enables_the_ai_gateway(self):
        documents = render_chart(
            "charts/apps/kora-api", "kora", "kora", "values-prod.yaml"
        )
        deployment = resource(documents, "Deployment", "kora-kora-api")
        seed_job = resource(documents, "Job", "kora-kora-api-seed")
        workload_secret = resource(documents, "ExternalSecret", "kora-kora-api-secrets")
        env = {
            entry["name"]: entry
            for entry in deployment["spec"]["template"]["spec"]["containers"][0][
                "env"
            ]
        }
        seed_env = {
            entry["name"]: entry
            for entry in seed_job["spec"]["template"]["spec"]["containers"][0][
                "env"
            ]
        }

        self.assertEqual("true", env["AI_GATEWAY_ENABLED"]["value"])
        self.assertEqual("kora-auto", env["AI_GATEWAY_MODEL"]["value"])
        self.assertEqual("60s", env["AI_AGENT_TIMEOUT"]["value"])
        self.assertEqual("true", seed_env["AI_GATEWAY_ENABLED"]["value"])
        self.assertEqual("kora-auto", seed_env["AI_GATEWAY_MODEL"]["value"])

        direct_provider_env = {
            "VERTEX_PROJECT",
            "VERTEX_LOCATION",
            "GEMINI_API_KEY",
            "OPENAI_API_KEY",
            "OPENAI_BASE_URL",
            "OPENAI_MODEL",
            "OPENAI_JSON_OBJECT",
        }
        self.assertTrue(direct_provider_env.isdisjoint(env))
        self.assertTrue(direct_provider_env.isdisjoint(seed_env))

        remote_refs = {
            entry["remoteRef"]["key"] for entry in workload_secret["spec"]["data"]
        }
        self.assertNotIn("prod-kora-gemini-api-key", remote_refs)
        self.assertNotIn("prod-kora-openai-api-key", remote_refs)

    def test_production_kora_api_resolves_agents_from_the_registry(self):
        documents = render_chart(
            "charts/apps/kora-api", "kora", "kora", "values-prod.yaml"
        )
        deployment = resource(documents, "Deployment", "kora-kora-api")
        env = {
            entry["name"]: entry
            for entry in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }

        # The cluster-local service, never the public host: aregistry.tesserix.app
        # is fronted by oauth2-proxy, which 401s a deploy key before the registry
        # sees it. Pinned because that misconfiguration is invisible at runtime --
        # routing just falls back to the keyword table.
        self.assertEqual(
            "http://agentregistry.agentregistry-system.svc.cluster.local:12121",
            env["AI_REGISTRY_BASE_URL"]["value"],
        )
        self.assertNotIn("aregistry.tesserix.app", env["AI_REGISTRY_BASE_URL"]["value"])
        self.assertEqual("5m", env["AI_REGISTRY_TTL"]["value"])

    def test_production_kora_api_may_egress_to_the_registry(self):
        documents = render_chart(
            "charts/apps/kora-api", "kora", "kora", "values-prod.yaml"
        )
        policy = resource(documents, "NetworkPolicy", "kora-ai-registry-egress")
        rule = policy["spec"]["egress"][0]

        # allow-kora-egress permits 0.0.0.0/0:443 except RFC1918, so without this
        # the roster fetch to a 10.x service just times out.
        self.assertEqual(
            "agentregistry-system",
            rule["to"][0]["namespaceSelector"]["matchLabels"][
                "kubernetes.io/metadata.name"
            ],
        )
        ports = {entry["port"] for entry in rule["ports"]}
        # 15008 is the ambient HBONE tunnel; without it ztunnel drops the hop.
        self.assertEqual({12121, 15008}, ports)

    def test_production_kora_api_carries_its_own_registry_deploy_key(self):
        documents = render_chart(
            "charts/apps/kora-api", "kora", "kora", "values-prod.yaml"
        )
        deployment = resource(documents, "Deployment", "kora-kora-api")
        env = {
            entry["name"]: entry
            for entry in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        deploy_key = resource(
            documents, "ExternalSecret", "kora-agentic-registry-deploy-key"
        )

        # The registry compares sha256(bearer) against its `kora=` entry, so the
        # gateway key authenticates as nobody. This chart shipped once without
        # the secret and every lookup 401'd behind a silent keyword fallback.
        source = env["AI_REGISTRY_API_KEY"]["valueFrom"]["secretKeyRef"]
        self.assertEqual("kora-agentic-registry-deploy-key", source["name"])
        self.assertEqual("api_key", source["key"])
        self.assertEqual(
            "prod-agentic-registry-kora-deploy-key",
            deploy_key["spec"]["data"][0]["remoteRef"]["key"],
        )
        self.assertEqual("api_key", deploy_key["spec"]["data"][0]["secretKey"])

    def test_gateway_disabled_leaves_the_agent_registry_unconfigured(self):
        documents = render_chart("charts/apps/kora-api", "kora", "kora")
        deployment = resource(documents, "Deployment", "kora-kora-api")
        env = {
            entry["name"]: entry
            for entry in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }

        # No gateway means no A2A transport, so a resolved card would be
        # unusable — the coach must fall through to the model provider. The
        # deploy key goes with it: an unused credential should not be synced.
        self.assertNotIn("AI_REGISTRY_BASE_URL", env)
        self.assertNotIn("AI_REGISTRY_API_KEY", env)
        self.assertIsNone(
            next(
                (
                    doc
                    for doc in documents
                    if doc.get("kind") == "NetworkPolicy"
                    and doc["metadata"]["name"] == "kora-ai-registry-egress"
                ),
                None,
            )
        )
        self.assertIsNone(
            next(
                (
                    doc
                    for doc in documents
                    if doc.get("kind") == "ExternalSecret"
                    and doc["metadata"]["name"] == "kora-agentic-registry-deploy-key"
                ),
                None,
            )
        )

    def test_gateway_disabled_does_not_enable_a_direct_provider_bypass(self):
        documents = render_chart("charts/apps/kora-api", "kora", "kora")
        deployment = resource(documents, "Deployment", "kora-kora-api")
        seed_job = resource(documents, "Job", "kora-kora-api-seed")
        workload_secret = resource(documents, "ExternalSecret", "kora-kora-api-secrets")

        api_env = {
            entry["name"]
            for entry in deployment["spec"]["template"]["spec"]["containers"][0][
                "env"
            ]
        }
        seed_env = {
            entry["name"]
            for entry in seed_job["spec"]["template"]["spec"]["containers"][0][
                "env"
            ]
        }
        remote_refs = {
            entry["remoteRef"]["key"] for entry in workload_secret["spec"]["data"]
        }

        provider_env = {
            "AI_GATEWAY_ENABLED",
            "VERTEX_PROJECT",
            "VERTEX_LOCATION",
            "GEMINI_API_KEY",
            "OPENAI_API_KEY",
            "OPENAI_BASE_URL",
            "OPENAI_MODEL",
            "OPENAI_JSON_OBJECT",
        }
        self.assertTrue(provider_env.isdisjoint(api_env))
        self.assertTrue(provider_env.isdisjoint(seed_env))
        self.assertNotIn("prod-kora-gemini-api-key", remote_refs)
        self.assertNotIn("prod-kora-openai-api-key", remote_refs)

    def test_ai_agents_are_non_root_bounded_and_gateway_only(self):
        documents = render_chart("charts/apps/kora-ai-agents", "kora-ai-agents", "kora")
        deployment = resource(documents, "Deployment", "kora-ai-agents")
        external_secret = resource(documents, "ExternalSecret", "kora-ai-agents")
        network_policy = resource(documents, "NetworkPolicy", "kora-ai-agents")

        pod = deployment["spec"]["template"]["spec"]
        container = pod["containers"][0]
        # The digest itself lives in values.yaml and moves on every deploy;
        # what this asserts is that it is mirrored and pinned, not mutable.
        repository, _, digest = container["image"].partition("@")
        self.assertEqual(
            "asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/"
            "tesserix/ai-agents",
            repository,
        )
        self.assertRegex(digest, r"^sha256:[0-9a-f]{64}$")
        self.assertTrue(pod["securityContext"]["runAsNonRoot"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual({"memory": "256Mi"}, container["resources"]["requests"])
        self.assertNotIn("cpu", container["resources"]["limits"])

        remote_keys = {
            entry["remoteRef"]["key"] for entry in external_secret["spec"]["data"]
        }
        self.assertEqual(
            {"prod-kora-ai-agents-api-key", "prod-kora-ai-gateway-api-key"},
            remote_keys,
        )
        gateway_egress = network_policy["spec"]["egress"][1]
        self.assertEqual(8080, gateway_egress["ports"][0]["port"])

        gateway_ingress = network_policy["spec"]["ingress"][0]["from"][0]
        self.assertEqual(
            "kora",
            gateway_ingress["namespaceSelector"]["matchLabels"][
                "kubernetes.io/metadata.name"
            ],
        )
        self.assertEqual(
            "waypoint",
            gateway_ingress["podSelector"]["matchLabels"][
                "gateway.networking.k8s.io/gateway-name"
            ],
        )

        native_gateway_ingress = network_policy["spec"]["ingress"][1]
        self.assertEqual(
            {
                "namespaceSelector": {
                    "matchLabels": {
                        "kubernetes.io/metadata.name": "agentgateway-system"
                    }
                },
                "podSelector": {
                    "matchLabels": {
                        "gateway.networking.k8s.io/gateway-name": "kora-ai"
                    }
                },
            },
            native_gateway_ingress["from"][0],
        )
        self.assertEqual(
            [8080, 15008],
            [entry["port"] for entry in native_gateway_ingress["ports"]],
        )

        authorization = resource(documents, "AuthorizationPolicy", "kora-ai-agents")
        authentication = resource(
            documents, "RequestAuthentication", "kora-ai-agents-user"
        )
        self.assertEqual(
            [{"group": "", "kind": "Service", "name": "kora-ai-agents"}],
            authentication["spec"]["targetRefs"],
        )
        self.assertEqual(
            [{"name": "X-Kora-End-User-Token", "prefix": "Bearer "}],
            authentication["spec"]["jwtRules"][0]["fromHeaders"],
        )
        self.assertNotIn("selector", authorization["spec"])
        self.assertEqual(
            [{"group": "", "kind": "Service", "name": "kora-ai-agents"}],
            authorization["spec"]["targetRefs"],
        )
        self.assertEqual(
            ["cluster.local/ns/agentgateway-system/sa/kora-ai"],
            authorization["spec"]["rules"][0]["from"][0]["source"]["principals"],
        )
        self.assertEqual(
            ["https://securetoken.google.com/kora-app-e6d38/*"],
            authorization["spec"]["rules"][0]["from"][0]["source"][
                "requestPrincipals"
            ],
        )
        operation = authorization["spec"]["rules"][0]["to"][0]["operation"]
        self.assertEqual(["POST"], operation["methods"])
        self.assertEqual(["/a2a/v1/*"], operation["paths"])

    def test_ai_agents_admit_gateway_hbone_to_the_kora_waypoint(self):
        documents = render_chart("charts/apps/kora-ai-agents", "kora-ai-agents", "kora")
        policy = resource(
            documents,
            "NetworkPolicy",
            "kora-ai-agents-waypoint-ingress",
        )

        self.assertEqual(
            {"gateway.networking.k8s.io/gateway-name": "waypoint"},
            policy["spec"]["podSelector"]["matchLabels"],
        )
        ingress = policy["spec"]["ingress"][0]
        self.assertEqual(
            {
                "namespaceSelector": {
                    "matchLabels": {
                        "kubernetes.io/metadata.name": "agentgateway-system"
                    }
                }
            },
            ingress["from"][0],
        )
        self.assertNotIn("ports", ingress)

    def test_token_optimizer_pulls_cpu_image_from_first_party_registry(self):
        documents = render_chart(
            "charts/apps/token-optimizer",
            "token-optimizer",
            "agentgateway-system",
        )
        deployment = resource(documents, "Deployment", "token-optimizer")
        pod = deployment["spec"]["template"]["spec"]
        image = pod["containers"][0]["image"]

        self.assertEqual(
            "asia-south1-docker.pkg.dev/tesseracthub-480811/global/token-optimizer",
            image.split("@")[0],
        )
        self.assertEqual(
            "sha256:58958f8dc92ab4ab70183c203ab92cfac26d0d716482adfc6f7ebbd6a9bad41a",
            image.split("@")[1],
        )
        self.assertNotIn("imagePullSecrets", pod)
        self.assertEqual(
            {"maxSurge": 0, "maxUnavailable": 1},
            deployment["spec"]["strategy"]["rollingUpdate"],
        )

    def test_registry_publish_path_is_credential_gated(self):
        registry = render_chart(
            "charts/apps/agentic-registry",
            "agentic-registry",
            "agentregistry-system",
            "values-prod.yaml",
        )
        config = resource(registry, "ConfigMap", "agentregistry-config")
        deployment = resource(registry, "Deployment", "agentregistry")
        self.assertEqual("read", config["data"]["AUTH_ANONYMOUS_ROLE"])

        env = {
            entry["name"]: entry
            for entry in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertIn("AUTH_DEPLOY_KEYS", env)
        self.assertIn("kora=$(KORA_DEPLOY_KEY_SHA256)", env["AUTH_DEPLOY_KEYS"]["value"])
        self.assertIn("devai=$(DEVAI_DEPLOY_KEY_SHA256)", env["AUTH_DEPLOY_KEYS"]["value"])

        bootstrap = render_chart(
            "charts/apps/devai-registry-bootstrap", "devai-registry-bootstrap", "devai"
        )
        job = next(document for document in bootstrap if document.get("kind") == "Job")
        upsert = job["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(
            "agentic-registry-deploy-key",
            upsert["env"][0]["valueFrom"]["secretKeyRef"]["name"],
        )

    def test_the_registry_accepts_ingress_from_kora(self):
        # Egress from kora is only half the path. Without kora in the control
        # plane's own ingress allowlist the packets are dropped there, and a
        # drop is indistinguishable from an unreachable registry.
        mesh = render_chart(
            "charts/thirdparty/istio-config",
            "istio-config",
            "istio-system",
            "values-prod.yaml",
        )
        for name in (
            "allow-agentregistry-ingress",
            "allow-agentgateway-ingress",
            "allow-kagent-ingress",
        ):
            policy = resource(mesh, "NetworkPolicy", name)
            sources = {
                rule["from"][0]["namespaceSelector"]["matchLabels"][
                    "kubernetes.io/metadata.name"
                ]
                for rule in policy["spec"]["ingress"]
            }
            self.assertIn("kora", sources, name)
            self.assertIn("devai", sources, name)

    def test_the_waypoint_authorizes_kora_to_read_the_catalog(self):
        # The NetworkPolicy above only gets the packet to the waypoint. This
        # ALLOW policy denies everything it does not name, and a denial here
        # looks exactly like the drop it replaced: no response, no refusal.
        policies = load_yaml(
            ROOT / "manifests/agentic-istio/authorization-policy.yaml"
        )
        registry = next(
            document
            for document in policies
            if document
            and document.get("kind") == "AuthorizationPolicy"
            and document["metadata"]["name"] == "agentregistry-authz"
        )
        readers = {
            namespace
            for rule in registry["spec"]["rules"]
            for source in rule.get("from", [])
            for namespace in source["source"].get("namespaces", [])
            if any(
                "GET" in target["operation"].get("methods", [])
                and "/v0/*" in target["operation"].get("paths", [])
                for target in rule.get("to", [])
            )
        }
        self.assertIn("kora", readers)
        self.assertIn("devai", readers)

    def test_the_mesh_app_applies_before_it_prunes(self):
        # Namespaces prune ahead of NetworkPolicies, and a decommissioned
        # namespace still carrying tesserix.io/protected cannot be dropped, so
        # without PruneLast that one refusal blocks the ingress rules above
        # from ever reaching the cluster.
        application = load_yaml(
            ROOT / "argocd/prod/infrastructure/istio-config.yaml"
        )[0]
        self.assertIn(
            "PruneLast=true",
            application["spec"]["syncPolicy"]["syncOptions"],
        )


if __name__ == "__main__":
    unittest.main()
