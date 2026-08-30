import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]


def render_chart(chart, release, namespace, values=()):
    chart_path = ROOT / chart
    subprocess.run(
        ["helm", "dependency", "build", str(chart_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    command = ["helm", "template", release, str(chart_path), "--namespace", namespace]
    if chart == "charts/apps/devai-ai-gateway":
        command.extend(["--set", "registryOwnership.enabled=false"])
    for value in values:
        command.extend(["--values", str(ROOT / chart / value)])
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents, kind, name):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


class DevAIGatewayAndSecretsTests(unittest.TestCase):
    def test_dashboard_owns_its_content_security_policy(self):
        documents = [
            document
            for document in yaml.safe_load_all(
                (ROOT / "manifests/devai-istio/virtualservice.yaml").read_text()
            )
            if document
        ]
        virtual_service = resource(documents, "VirtualService", "devai-platform")
        dashboard_route = next(
            route
            for route in virtual_service["spec"]["http"]
            if route.get("match") == [{"uri": {"prefix": "/"}}]
        )

        response_headers = dashboard_route.get("headers", {}).get("response", {})
        self.assertNotIn(
            "content-security-policy",
            response_headers.get("set", {}),
        )

    def test_llm_gateway_is_native_agentgateway_with_every_provider(self):
        documents = render_chart(
            "charts/apps/devai-ai-gateway", "devai-ai-gateway", "agentgateway-system"
        )
        parameters = resource(documents, "AgentgatewayParameters", "ai-gateway")
        gateway = resource(documents, "Gateway", "ai-gateway")
        self.assertEqual("agentgateway", gateway["spec"]["gatewayClassName"])
        self.assertTrue(parameters["spec"]["istio"]["enabled"])
        self.assertFalse(
            any(
                document.get("kind") == "Deployment"
                and document.get("metadata", {}).get("name") == "devai-ai-gateway"
                for document in documents
            )
        )

        expected = {
            "devai-anthropic",
            "devai-openai",
            "devai-vertex",
            "devai-vertex-api-key",
            "devai-gemini",
            "devai-groq",
            "devai-openrouter",
            "devai-nemoclaw",
            "ai-zitadel-jwks",
        }
        actual = {
            document["metadata"]["name"]
            for document in documents
            if document.get("kind") == "AgentgatewayBackend"
        }
        self.assertEqual(expected, actual)

    def test_vertex_route_uses_workload_identity_and_retains_rollback_key(self):
        documents = render_chart(
            "charts/apps/devai-ai-gateway", "devai-ai-gateway", "agentgateway-system"
        )
        backend = resource(documents, "AgentgatewayBackend", "devai-vertex-api-key")
        external_secret = resource(
            documents, "ExternalSecret", "devai-ai-gateway-secrets"
        )
        provider = backend["spec"]["ai"]["groups"][0]["providers"][0]

        self.assertEqual("vertex", provider["name"])
        self.assertEqual("aiplatform.googleapis.com", provider["host"])
        self.assertEqual({"gcp": {}}, provider["policies"]["auth"])
        self.assertIn(
            {
                "secretKey": "VERTEX_API_KEY",
                "remoteRef": {"key": "prod-devai-vertex-api-key"},
            },
            external_secret["spec"]["data"],
        )

    def test_gateway_routes_are_provider_specific_and_private(self):
        documents = render_chart(
            "charts/apps/devai-ai-gateway", "devai-ai-gateway", "agentgateway-system"
        )
        route = resource(documents, "HTTPRoute", "devai-ai")
        self.assertEqual(
            {
                "group": "gateway.networking.k8s.io",
                "kind": "Gateway",
                "name": "ai-gateway",
                "sectionName": "http",
            },
            route["spec"]["parentRefs"][0],
        )
        self.assertTrue(
            all(
                ref.get("weight") == 1
                for rule in route["spec"]["rules"]
                for ref in rule["backendRefs"]
            )
        )
        backends = {
            ref["name"]
            for rule in route["spec"]["rules"]
            for ref in rule["backendRefs"]
        }
        self.assertEqual(
            {
                "devai-anthropic",
                "devai-openai",
                "devai-vertex-api-key",
                "devai-gemini",
                "devai-groq",
                "devai-openrouter",
                "devai-nemoclaw",
            },
            backends,
        )
        policy = resource(documents, "AuthorizationPolicy", "ai-gateway")
        principals = policy["spec"]["rules"][0]["from"][0]["source"]["principals"]
        self.assertEqual(
            {
                "cluster.local/ns/devai/sa/devai-api",
                "cluster.local/ns/devai/sa/devai-runner",
                "cluster.local/ns/ai-agents/sa/sre-ai-agent",
            },
            set(principals),
        )
        network_policy = resource(documents, "NetworkPolicy", "ai-gateway")
        ingress_selectors = {
            tuple(sorted(source.get("podSelector", {}).get("matchLabels", {}).items()))
            for rule in network_policy["spec"]["ingress"]
            for source in rule.get("from", [])
            if source.get("namespaceSelector", {})
            .get("matchLabels", {})
            .get("kubernetes.io/metadata.name")
            == "devai"
        }
        self.assertIn((("app.kubernetes.io/name", "devai-api"),), ingress_selectors)
        self.assertIn(
            (("app.kubernetes.io/name", "devai-api-worker"),), ingress_selectors
        )
        self.assertIn((("devai.tesserix.app/role", "runner"),), ingress_selectors)
        sre_ingress = {
            tuple(sorted(source.get("podSelector", {}).get("matchLabels", {}).items()))
            for rule in network_policy["spec"]["ingress"]
            for source in rule.get("from", [])
            if source.get("namespaceSelector", {})
            .get("matchLabels", {})
            .get("kubernetes.io/metadata.name")
            == "ai-agents"
        }
        self.assertEqual(
            {(("app.kubernetes.io/name", "sre-ai-agent"),)},
            sre_ingress,
        )

    def test_gateway_vertex_identity_is_terraform_bound(self):
        documents = render_chart(
            "charts/apps/devai-ai-gateway", "devai-ai-gateway", "agentgateway-system"
        )
        parameters = resource(documents, "AgentgatewayParameters", "ai-gateway")
        annotations = parameters["spec"]["serviceAccount"]["metadata"]["annotations"]
        self.assertEqual(
            "agentgateway-llm@tesseracthub-480811.iam.gserviceaccount.com",
            annotations["iam.gke.io/gcp-service-account"],
        )
        main = (ROOT / "terraform-new/stacks/12-vertex/main.tf").read_text()
        variables = (ROOT / "terraform-new/stacks/12-vertex/variables.tf").read_text()
        production = (
            ROOT / "terraform-new/environments/prod/terraform.tfvars"
        ).read_text()
        self.assertIn(
            'resource "google_service_account_iam_member" "devai_agentgateway_wi"', main
        )
        self.assertIn('variable "devai_agentgateway_ksa"', variables)
        self.assertNotIn(
            'resource "google_project_iam_member" "devai_workload_secretmanager_admin"',
            main,
        )
        self.assertRegex(
            production,
            r'devai_agentgateway_ksa\s*=\s*"agentgateway-system/ai-gateway"',
        )

    def test_gateway_bypasses_waypoint_and_metadata_capture(self):
        documents = render_chart(
            "charts/apps/devai-ai-gateway", "devai-ai-gateway", "agentgateway-system"
        )
        parameters = resource(documents, "AgentgatewayParameters", "ai-gateway")
        metadata = parameters["spec"]["deployment"]["spec"]["template"]["metadata"]

        self.assertEqual("none", metadata["labels"]["istio.io/use-waypoint"])
        self.assertEqual(
            "169.254.169.254/32",
            metadata["annotations"][
                "traffic.sidecar.istio.io/excludeOutboundIPRanges"
            ],
        )

    def test_devai_production_requires_gateway_for_llm_and_mcp(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        deployment = resource(documents, "Deployment", "devai-api")
        env = {
            item["name"]: item.get("value")
            for item in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertEqual("true", env["DEVAI_LLM_GATEWAY_REQUIRED"])
        self.assertEqual(
            "http://ai-gateway.agentgateway-system.svc.cluster.local:8080",
            env["DEVAI_LLM_GATEWAY_BASE_URL"],
        )
        self.assertEqual(
            "http://ai-gateway.agentgateway-system.svc.cluster.local:8080/openai/v1",
            env["DEVAI_OPENAI_BASE_URL"],
        )
        self.assertEqual(
            "http://agentgateway-mcp.agentgateway-system.svc.cluster.local:8080",
            env["DEVAI_AGENTGATEWAY_URL"],
        )
        self.assertEqual("vertex_gemini", env["DEVAI_LLM_PROVIDER"])
        self.assertEqual("anthropic", env["DEVAI_LLM_FALLBACK_PROVIDER"])
        self.assertEqual("auto", env["DEVAI_EMBEDDING_PROVIDER"])
        self.assertEqual("768", env["DEVAI_EMBEDDING_DIMENSIONS"])
        self.assertEqual(
            "devai_memories_vertex_768",
            env["DEVAI_QDRANT_COLLECTION"],
        )
        self.assertEqual("vertex_gemini:gemini-2.5-flash", env["DEVAI_LLM_TIER_LIGHT"])
        self.assertEqual("vertex_gemini:gemini-2.5-flash", env["DEVAI_LLM_TIER_STANDARD"])
        self.assertEqual("vertex_gemini:gemini-2.5-flash", env["DEVAI_LLM_TIER_HEAVY"])
        self.assertEqual("vertex_gemini:gemini-2.5-flash", env["DEVAI_LLM_TIER_FRONTIER"])
        self.assertEqual("openbao", env["DEVAI_SECRETS_PROVIDER"])

    def test_devai_production_uses_durable_evaluation_object_storage(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        deployment = resource(documents, "Deployment", "devai-api")
        env = {
            item["name"]: item.get("value")
            for item in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }

        self.assertEqual("gcs", env["DEVAI_OBJECT_STORE_PROVIDER"])
        self.assertEqual("devai-prod-evaluations-in", env["DEVAI_OBJECT_STORE_BUCKET"])
        self.assertEqual("devai", env["DEVAI_OBJECT_STORE_PREFIX"])

    def test_devai_production_temporal_is_tenant_safe_and_fail_closed(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        api = resource(documents, "Deployment", "devai-api")
        worker = resource(documents, "Deployment", "devai-api-worker")

        for deployment in (api, worker):
            env = {
                item["name"]: item
                for item in deployment["spec"]["template"]["spec"]["containers"][0][
                    "env"
                ]
            }
            self.assertEqual("temporal", env["DEVAI_WORKFLOW_PROVIDER"]["value"])
            self.assertEqual(
                "temporal-frontend.temporal-system.svc.cluster.local:7233",
                env["DEVAI_TEMPORAL_HOST"]["value"],
            )
            self.assertEqual("devai", env["DEVAI_TEMPORAL_NAMESPACE"]["value"])
            self.assertEqual("true", env["DEVAI_TEMPORAL_FAIL_CLOSED"]["value"])
            self.assertEqual(
                "true",
                env["DEVAI_TEMPORAL_PAYLOAD_ENCRYPTION_REQUIRED"]["value"],
            )
            self.assertEqual(
                {
                    "name": "devai-api-secrets",
                    "key": "DEVAI_TEMPORAL_PAYLOAD_ENCRYPTION_KEY",
                },
                env["DEVAI_TEMPORAL_PAYLOAD_ENCRYPTION_KEY"]["valueFrom"][
                    "secretKeyRef"
                ],
            )

        worker_env = {
            item["name"]: item.get("value")
            for item in worker["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertEqual(
            "true", worker_env["DEVAI_TEMPORAL_WORKER_DEPENDENCIES_REQUIRED"]
        )
        self.assertEqual("true", worker_env["DEVAI_TEMPORAL_WORKER_VERSIONING_ENABLED"])
        self.assertEqual("devai", worker_env["DEVAI_TEMPORAL_WORKER_DEPLOYMENT_NAME"])
        self.assertEqual(
            "fix-multi-provider-user-routing-c5d89ea",
            worker_env["DEVAI_TEMPORAL_WORKER_BUILD_ID"],
        )

    def test_devai_adk_workloads_run_as_the_image_user(self):
        api_documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        sre_documents = render_chart(
            "charts/apps/devai-sre",
            "devai-sre",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )

        for deployment in (
            resource(api_documents, "Deployment", "devai-api"),
            resource(api_documents, "Deployment", "devai-api-worker"),
            resource(sre_documents, "Deployment", "devai-sre"),
        ):
            pod_security = deployment["spec"]["template"]["spec"]["securityContext"]
            self.assertEqual(10001, pod_security["runAsUser"])
            self.assertTrue(pod_security["runAsNonRoot"])

    def test_devai_cluster_reader_has_distinct_istio_and_knative_rules(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        cluster_role = resource(documents, "ClusterRole", "devai-api-cluster-reader")
        rules = {
            tuple(rule["apiGroups"]): rule
            for rule in cluster_role["rules"]
            if "apiGroups" in rule
        }

        self.assertEqual(
            ["virtualservices", "destinationrules", "gateways"],
            rules[("networking.istio.io",)]["resources"],
        )
        self.assertEqual(
            ["services", "revisions", "routes"],
            rules[("serving.knative.dev",)]["resources"],
        )

    def test_devai_sre_cluster_reader_has_distinct_istio_and_knative_rules(self):
        documents = render_chart(
            "charts/apps/devai-sre",
            "devai-sre",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        cluster_role = resource(documents, "ClusterRole", "devai-sre-cluster-reader")
        rules = {
            tuple(rule["apiGroups"]): rule
            for rule in cluster_role["rules"]
            if "apiGroups" in rule
        }

        self.assertEqual(
            [
                "peerauthentications",
                "authorizationpolicies",
                "requestauthentications",
            ],
            rules[("security.istio.io",)]["resources"],
        )
        self.assertEqual(
            ["services", "revisions", "routes", "configurations"],
            rules[("serving.knative.dev",)]["resources"],
        )

    def test_devai_production_pins_adk_images_by_digest(self):
        release_tag = "fix-multi-provider-user-routing-c5d89ea"
        api_tag = (
            f"{release_tag}@"
            "sha256:b7c12bce32ce5ed8712034f73bf2688ba26ce1a963a430c1e689777e2704772e"
        )
        sre_tag = (
            f"{release_tag}@"
            "sha256:23feec0dc1c04f25cfdc79864edbe45accd8aab6cc308a5b9f5b7dfc53516f6a"
        )
        runner_image = (
            "asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/"
            f"tesserix/devai/devai-runner:{release_tag}@"
            "sha256:2d0298a342c01e76b59482e3e4276b7c08c597070ebd7de757d845c15f672625"
        )
        api_documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        sre_documents = render_chart(
            "charts/apps/devai-sre",
            "devai-sre",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )

        api = resource(api_documents, "Deployment", "devai-api")
        worker = resource(api_documents, "Deployment", "devai-api-worker")
        sre = resource(sre_documents, "Deployment", "devai-sre")
        api_repository = (
            "asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/"
            "tesserix/devai/devai"
        )
        sre_repository = f"{api_repository}-sre"
        self.assertEqual(
            f"{api_repository}:{api_tag}",
            api["spec"]["template"]["spec"]["containers"][0]["image"],
        )
        self.assertEqual(
            f"{api_repository}:{api_tag}",
            worker["spec"]["template"]["spec"]["containers"][0]["image"],
        )
        self.assertEqual(
            f"{sre_repository}:{sre_tag}",
            sre["spec"]["template"]["spec"]["containers"][0]["image"],
        )

        api_env = {
            item["name"]: item.get("value")
            for item in api["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertEqual(runner_image, api_env["DEVAI_RUNNER_IMAGE"])

        expected_parameters = {
            "argocd/prod/apps/ai-apps/devai-api.yaml": {
                "image.tag": api_tag,
                "k8sRuntime.runnerImage": runner_image,
            },
            "argocd/prod/apps/ai-apps/devai-sre.yaml": {"image.tag": sre_tag},
        }
        for relative_path, expected in expected_parameters.items():
            application = yaml.safe_load(
                (ROOT / relative_path).read_text(encoding="utf-8")
            )
            parameters = {
                item["name"]: item["value"]
                for item in application["spec"]["source"]["helm"]["parameters"]
            }
            self.assertEqual(expected, parameters)

    def test_mcp_bridge_uses_verified_direct_gar_image(self):
        documents = render_chart(
            "charts/apps/devai-mcp-bridge",
            "devai-mcp-bridge",
            "devai",
        )
        deployment = resource(documents, "Deployment", "devai-mcp-bridge")

        self.assertEqual(
            "asia-south1-docker.pkg.dev/tesseracthub-480811/global/"
            "devai-mcp-bridge:latest",
            deployment["spec"]["template"]["spec"]["containers"][0]["image"],
        )

    def test_global_adk_runtime_api_is_multi_zone_and_disruption_safe(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        deployment = resource(documents, "Deployment", "devai-api")
        pod = deployment["spec"]["template"]["spec"]
        container = pod["containers"][0]
        scaler = resource(documents, "ScaledObject", "devai-api")

        self.assertEqual(3, scaler["spec"]["minReplicaCount"])
        self.assertEqual(9, scaler["spec"]["maxReplicaCount"])
        self.assertEqual(
            {
                "type": "RollingUpdate",
                "rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1},
            },
            deployment["spec"]["strategy"],
        )
        self.assertEqual(
            {"kubernetes.io/hostname", "topology.kubernetes.io/zone"},
            {item["topologyKey"] for item in pod["topologySpreadConstraints"]},
        )
        self.assertGreaterEqual(pod["terminationGracePeriodSeconds"], 930)
        self.assertEqual(
            ["/bin/sh", "-c", "sleep 5"],
            container["lifecycle"]["preStop"]["exec"]["command"],
        )
        self.assertNotIn("cpu", container["resources"]["requests"])
        self.assertNotIn("cpu", container["resources"]["limits"])

        pdb = resource(documents, "PodDisruptionBudget", "devai-api")
        self.assertEqual(2, pdb["spec"]["minAvailable"])

    def test_global_adk_runtime_has_a_stable_service_alias(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        service = resource(documents, "Service", "adk-runtime")

        self.assertEqual("none", service["metadata"]["labels"]["istio.io/use-waypoint"])
        self.assertEqual(
            {
                "app.kubernetes.io/name": "devai-api",
                "app.kubernetes.io/instance": "devai-api",
            },
            service["spec"]["selector"],
        )
        self.assertEqual(8080, service["spec"]["ports"][0]["port"])

    def test_global_adk_runtime_is_internal_and_zitadel_authenticated(self):
        documents = render_chart(
            "charts/apps/agentgateway-route-sync",
            "agentgateway-route-sync",
            "agentgateway-system",
        )
        backend = resource(documents, "AgentgatewayBackend", "global-adk-runtime")
        route = resource(documents, "HTTPRoute", "global-adk-runtime")
        policy = resource(documents, "AgentgatewayPolicy", "global-adk-runtime")
        observability = resource(
            documents,
            "AgentgatewayPolicy",
            "global-adk-runtime-observability",
        )
        secret = resource(documents, "ExternalSecret", "global-adk-runtime-upstream")

        self.assertEqual(
            {"host": "adk-runtime.devai.svc.cluster.local", "port": 8080},
            backend["spec"]["a2a"],
        )
        self.assertEqual("runtime", route["spec"]["parentRefs"][0]["sectionName"])
        self.assertEqual(
            [
                {"path": {"type": "PathPrefix", "value": "/a2a/v1/"}},
                {
                    "path": {
                        "type": "Exact",
                        "value": "/.well-known/agent-card.json",
                    }
                },
            ],
            route["spec"]["rules"][0]["matches"],
        )
        self.assertEqual(
            "global-adk-runtime",
            route["spec"]["rules"][0]["backendRefs"][0]["name"],
        )
        self.assertEqual(
            [
                {
                    "group": "gateway.networking.k8s.io",
                    "kind": "Gateway",
                    "name": "agentgateway-mcp",
                    "sectionName": "runtime",
                }
            ],
            policy["spec"]["targetRefs"],
        )
        self.assertEqual(
            [
                {
                    "group": "gateway.networking.k8s.io",
                    "kind": "Gateway",
                    "name": "agentgateway-mcp",
                    "sectionName": "runtime",
                }
            ],
            observability["spec"]["targetRefs"],
        )
        self.assertEqual(
            [
                {"name": "auth.subject", "expression": "jwt.sub"},
                {"name": "auth.client_id", "expression": "jwt.client_id"},
            ],
            observability["spec"]["frontend"]["accessLog"]["attributes"]["add"],
        )

        traffic = policy["spec"]["traffic"]
        provider = traffic["jwtAuthentication"]["providers"][0]
        self.assertEqual("Strict", traffic["jwtAuthentication"]["mode"])
        self.assertEqual("https://auth.tesserix.app", provider["issuer"])
        self.assertEqual(["387190457387450503"], provider["audiences"])
        self.assertEqual(
            [
                '"agentgateway.runtime" in jwt['
                '"urn:zitadel:iam:org:project:387190457387450503:roles"]'
            ],
            traffic["authorization"]["policy"]["matchExpressions"],
        )
        self.assertEqual(
            [
                {"name": "X-ADK-Workload-Subject", "value": "jwt.sub"},
                {"name": "X-ADK-Workload-Client-ID", "value": "jwt.client_id"},
            ],
            traffic["transformation"]["request"]["set"],
        )
        self.assertEqual(
            [{"requests": 1800, "unit": "Minutes", "burst": 200}],
            traffic["rateLimit"]["local"],
        )
        self.assertEqual(
            {
                "backendRef": {"name": "agentgateway-ratelimit", "port": 8081},
                "domain": "agentgateway-public",
                "failureMode": "FailClosed",
                "descriptors": [
                    {
                        "entries": [
                            {"name": "gateway", "expression": '"runtime"'},
                            {"name": "oauth_subject", "expression": "jwt.sub"},
                        ],
                        "unit": "Requests",
                    }
                ],
            },
            traffic["rateLimit"]["global"],
        )
        self.assertEqual({"request": "15m"}, traffic["timeouts"])
        self.assertEqual(
            {
                "secretRef": {
                    "name": "global-adk-runtime-upstream",
                    "key": "token",
                },
                "location": {
                    "header": {"name": "Authorization", "prefix": "Bearer "}
                },
            },
            policy["spec"]["backend"]["auth"],
        )
        self.assertEqual(
            [
                {
                    "secretKey": "token",
                    "remoteRef": {
                        "key": "prod-global-adk-runtime-upstream-token"
                    },
                }
            ],
            secret["spec"]["data"],
        )

        rate_limit_documents = list(
            yaml.safe_load_all(
                (ROOT / "manifests/agentic-istio/ratelimit.yaml").read_text()
            )
        )
        rate_limit_config = yaml.safe_load(
            resource(
                rate_limit_documents,
                "ConfigMap",
                "agentgateway-ratelimit",
            )["data"]["config.yaml"]
        )
        runtime = next(
            descriptor
            for descriptor in rate_limit_config["descriptors"]
            if descriptor.get("value") == "runtime"
        )
        self.assertEqual("gateway", runtime["key"])
        self.assertEqual(
            {"unit": "minute", "requests_per_unit": 1800},
            runtime["descriptors"][0]["rate_limit"],
        )

    def test_global_adk_runtime_token_is_injected_into_devai(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        deployment = resource(documents, "Deployment", "devai-api")
        env = {
            item["name"]: item
            for item in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertEqual(
            {
                "name": "devai-api-secrets",
                "key": "DEVAI_ADK_RUNTIME_SERVICE_TOKEN",
                "optional": True,
            },
            env["DEVAI_ADK_RUNTIME_SERVICE_TOKEN"]["valueFrom"]["secretKeyRef"],
        )
        self.assertEqual(
            "http://agentgateway-mcp.agentgateway-system.svc.cluster.local:8082",
            env["DEVAI_ADK_RUNTIME_BASE_URL"]["value"],
        )

        external_secrets = list(
            yaml.safe_load_all(
                (ROOT / "external-secrets/prod/devai/externalsecret.yaml").read_text()
            )
        )
        secret = resource(external_secrets, "ExternalSecret", "devai-api-secrets")
        mappings = {
            item["secretKey"]: item["remoteRef"]["key"]
            for item in secret["spec"]["data"]
        }
        self.assertEqual(
            "prod-global-adk-runtime-upstream-token",
            mappings["DEVAI_ADK_RUNTIME_SERVICE_TOKEN"],
        )

    def test_zitadel_declares_the_global_runtime_machine_role(self):
        values = yaml.safe_load(
            (ROOT / "charts/apps/zitadel-bootstrap/values.yaml").read_text()
        )
        project = next(
            item
            for item in values["desired"]["platformProjects"]
            if item["name"] == "AgentGateway"
        )

        self.assertIn(
            {
                "key": "agentgateway.runtime",
                "displayName": "ADK Runtime",
                "group": "gateway-access",
            },
            project["roles"],
        )
        self.assertIn(
            {
                "login": "agentgateway-adk-prod",
                "roles": [
                    "agentgateway.mcp",
                    "agentgateway.models",
                    "agentgateway.runtime",
                ],
            },
            project["machineGrants"],
        )

    def test_devai_temporal_workers_are_ha_hardened_and_promoted(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        worker = resource(documents, "Deployment", "devai-api-worker")
        spec = worker["spec"]
        pod = spec["template"]["spec"]
        container = pod["containers"][0]

        self.assertEqual(2, spec["replicas"])
        self.assertGreaterEqual(pod["terminationGracePeriodSeconds"], 90)
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertIn("livenessProbe", container)
        self.assertIn("startupProbe", container)
        self.assertEqual(
            {"kubernetes.io/hostname", "topology.kubernetes.io/zone"},
            {
                item["topologyKey"]
                for item in spec["template"]["spec"]["topologySpreadConstraints"]
            },
        )

        pdb = resource(documents, "PodDisruptionBudget", "devai-api-worker")
        self.assertEqual(1, pdb["spec"]["minAvailable"])

        promotion = resource(documents, "Job", "devai-api-worker-version")
        self.assertEqual(
            "devai-api",
            promotion["spec"]["template"]["spec"]["serviceAccountName"],
        )
        command = " ".join(
            promotion["spec"]["template"]["spec"]["containers"][0]["args"]
        )
        self.assertIn("worker deployment set-current-version", command)
        self.assertIn("--deployment-name", command)
        self.assertIn("--build-id", command)

    def test_devai_agent_lifecycle_alerts_cover_the_byoa_operational_signals(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        rules = resource(documents, "PrometheusRule", "devai-api-agent-lifecycle")
        alerts = {
            rule["alert"]: rule
            for group in rules["spec"]["groups"]
            for rule in group["rules"]
        }
        self.assertEqual(
            {
                "DevAIAgentLifecycleQueueOld",
                "DevAISandboxCapacityPressure",
                "DevAIAgentLifecycleStuck",
                "DevAISandboxCleanupBacklog",
                "DevAIAuthenticationFailures",
                "DevAIAgentImportFailures",
                "DevAIAgentEvaluationFailures",
                "DevAISandboxQuotaPressure",
                "GlobalADKRuntimeBackendHADegraded",
                "GlobalADKRuntimeGatewayHADegraded",
            },
            set(alerts),
        )
        for name, rule in alerts.items():
            self.assertEqual("devai-platform", rule["labels"]["owner"])
            runbook = (
                "global-adk-runtime.md"
                if name.startswith("GlobalADKRuntime")
                else "devai-agent-lifecycle.md"
            )
            self.assertTrue(rule["annotations"]["runbook_url"].endswith(runbook))

    def test_devai_temporal_egress_allows_frontend_and_hbone(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        policy = resource(documents, "NetworkPolicy", "devai-temporal-egress")
        rule = policy["spec"]["egress"][0]
        self.assertEqual([{"protocol": "TCP", "port": 7233}], rule["ports"])
        self.assertEqual(
            "temporal-system",
            rule["to"][0]["namespaceSelector"]["matchLabels"][
                "kubernetes.io/metadata.name"
            ],
        )
        self.assertEqual(
            "frontend",
            rule["to"][0]["podSelector"]["matchLabels"]["app.kubernetes.io/component"],
        )

        hbone_rule = policy["spec"]["egress"][1]
        self.assertEqual([{"protocol": "TCP", "port": 15008}], hbone_rule["ports"])
        self.assertEqual(
            "10.20.0.0/16",
            hbone_rule["to"][0]["ipBlock"]["cidr"],
        )

    def test_devai_temporal_payload_key_is_sourced_from_secret_manager(self):
        documents = list(
            yaml.safe_load_all(
                (ROOT / "external-secrets/prod/devai/externalsecret.yaml").read_text()
            )
        )
        secret = resource(documents, "ExternalSecret", "devai-api-secrets")
        mappings = {
            item["secretKey"]: item["remoteRef"]["key"]
            for item in secret["spec"]["data"]
        }
        self.assertEqual(
            "prod-devai-temporal-payload-key",
            mappings["DEVAI_TEMPORAL_PAYLOAD_ENCRYPTION_KEY"],
        )

    def test_devai_registry_writes_use_tenant_scoped_deploy_key(self):
        documents = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        deployment = resource(documents, "Deployment", "devai-api")
        env = {
            item["name"]: item
            for item in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }

        self.assertEqual(
            {
                "name": "agentic-registry-deploy-key",
                "key": "API_KEY",
            },
            env["DEVAI_REGISTRY_TOKEN"]["valueFrom"]["secretKeyRef"],
        )

    def test_devai_sre_agentgateway_url_targets_mcp_data_plane(self):
        documents = render_chart(
            "charts/apps/devai-sre",
            "devai-sre",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        deployment = resource(documents, "Deployment", "devai-sre")
        env = {
            item["name"]: item.get("value")
            for item in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertEqual(
            "http://agentgateway-mcp.agentgateway-system.svc.cluster.local:8080",
            env["DEVAI_AGENTGATEWAY_URL"],
        )

    def test_devai_sre_production_requires_the_provider_ai_gateway(self):
        documents = render_chart(
            "charts/apps/devai-sre",
            "devai-sre",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        deployment = resource(documents, "Deployment", "devai-sre")
        env = {
            item["name"]: item.get("value")
            for item in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertEqual("true", env["DEVAI_LLM_GATEWAY_REQUIRED"])
        self.assertEqual(
            "http://ai-gateway.agentgateway-system.svc.cluster.local:8080",
            env["DEVAI_LLM_GATEWAY_BASE_URL"],
        )

    def test_secret_service_broker_uses_tokenreview_and_fixed_openbao_scope(self):
        documents = render_chart(
            "charts/apps/secret-service", "secret-service", "secret-service"
        )
        deployment = resource(documents, "Deployment", "secret-service-api")
        pod = deployment["spec"]["template"]["spec"]
        env = {item["name"]: item.get("value") for item in pod["containers"][0]["env"]}
        self.assertEqual("true", env["WORKLOAD_SECRET_BROKER_ENABLED"])
        self.assertEqual("devai", env["WORKLOAD_SECRET_NAMESPACE"])
        self.assertEqual("devai-api", env["WORKLOAD_SECRET_APP"])
        role = resource(documents, "ClusterRole", "secret-service-discovery")
        self.assertTrue(
            any(
                rule.get("apiGroups") == ["authentication.k8s.io"]
                and rule.get("resources") == ["tokenreviews"]
                and rule.get("verbs") == ["create"]
                for rule in role["rules"]
            )
        )

        openbao_values = yaml.safe_load(
            (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
        )
        policies = {
            item["name"]: item["hcl"]
            for item in openbao_values["bootstrap"]["policies"]
        }
        self.assertIn('path "kv/data/devai/devai-api/*"', policies["read-devai-api"])
        self.assertNotIn('capabilities = ["create"', policies["read-devai-api"])
        roles = {
            item["name"]: item
            for item in openbao_values["bootstrap"]["kubernetesRoles"]
        }
        self.assertEqual(["devai-api"], roles["read-devai-api"]["serviceAccounts"])
        self.assertEqual(["devai"], roles["read-devai-api"]["namespaces"])

        openbao_namespace = render_chart(
            "charts/apps/openbao-namespace", "openbao-namespace", "openbao"
        )
        policy = resource(
            openbao_namespace, "NetworkPolicy", "allow-clients-to-openbao"
        )
        devai_selectors = {
            tuple(sorted(source.get("podSelector", {}).get("matchLabels", {}).items()))
            for rule in policy["spec"]["ingress"]
            for source in rule.get("from", [])
            if source.get("namespaceSelector", {})
            .get("matchLabels", {})
            .get("kubernetes.io/metadata.name")
            == "devai"
        }
        self.assertIn((("app.kubernetes.io/name", "devai-api"),), devai_selectors)
        self.assertIn(
            (("app.kubernetes.io/name", "devai-api-worker"),), devai_selectors
        )

        devai = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        pod = resource(devai, "Deployment", "devai-api")["spec"]["template"]["spec"]
        projected = next(
            volume
            for volume in pod["volumes"]
            if volume["name"] == "secret-service-token"
        )
        token = projected["projected"]["sources"][0]["serviceAccountToken"]
        self.assertEqual("secret-service", token["audience"])
        mount = next(
            mount
            for mount in pod["containers"][0]["volumeMounts"]
            if mount["name"] == "secret-service-token"
        )
        self.assertEqual("/var/run/secrets/devai/secret-service", mount["mountPath"])


if __name__ == "__main__":
    unittest.main()
