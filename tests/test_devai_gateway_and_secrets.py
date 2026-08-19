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
        if document.get("kind") == kind and document.get("metadata", {}).get("name") == name
    )


class DevAIGatewayAndSecretsTests(unittest.TestCase):
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
                "devai-vertex",
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
            },
            set(principals),
        )
        network_policy = resource(documents, "NetworkPolicy", "ai-gateway")
        ingress_selectors = {
            tuple(sorted(source.get("podSelector", {}).get("matchLabels", {}).items()))
            for rule in network_policy["spec"]["ingress"]
            for source in rule.get("from", [])
            if source.get("namespaceSelector", {}).get("matchLabels", {}).get(
                "kubernetes.io/metadata.name"
            )
            == "devai"
        }
        self.assertIn((("app.kubernetes.io/name", "devai-api"),), ingress_selectors)
        self.assertIn((("app.kubernetes.io/name", "devai-api-worker"),), ingress_selectors)
        self.assertIn((("devai.tesserix.app/role", "runner"),), ingress_selectors)

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
        production = (ROOT / "terraform-new/environments/prod/terraform.tfvars").read_text()
        self.assertIn('resource "google_service_account_iam_member" "devai_agentgateway_wi"', main)
        self.assertIn('variable "devai_agentgateway_ksa"', variables)
        self.assertNotIn('resource "google_project_iam_member" "devai_workload_secretmanager_admin"', main)
        self.assertRegex(
            production,
            r'devai_agentgateway_ksa\s*=\s*"agentgateway-system/ai-gateway"',
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
            "http://agentgateway-mcp.agentgateway-system.svc.cluster.local:8080",
            env["DEVAI_AGENTGATEWAY_URL"],
        )
        self.assertEqual("openbao", env["DEVAI_SECRETS_PROVIDER"])

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

    def test_secret_service_broker_uses_tokenreview_and_fixed_openbao_scope(self):
        documents = render_chart("charts/apps/secret-service", "secret-service", "secret-service")
        deployment = resource(documents, "Deployment", "secret-service-api")
        pod = deployment["spec"]["template"]["spec"]
        env = {
            item["name"]: item.get("value")
            for item in pod["containers"][0]["env"]
        }
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

        openbao_values = yaml.safe_load((ROOT / "charts/thirdparty/openbao/values.yaml").read_text())
        policies = {item["name"]: item["hcl"] for item in openbao_values["bootstrap"]["policies"]}
        self.assertIn('path "kv/data/devai/devai-api/*"', policies["read-devai-api"])
        self.assertNotIn('capabilities = ["create"', policies["read-devai-api"])
        roles = {item["name"]: item for item in openbao_values["bootstrap"]["kubernetesRoles"]}
        self.assertEqual(["devai-api"], roles["read-devai-api"]["serviceAccounts"])
        self.assertEqual(["devai"], roles["read-devai-api"]["namespaces"])

        openbao_namespace = render_chart(
            "charts/apps/openbao-namespace", "openbao-namespace", "openbao"
        )
        policy = resource(openbao_namespace, "NetworkPolicy", "allow-clients-to-openbao")
        devai_selectors = {
            tuple(sorted(source.get("podSelector", {}).get("matchLabels", {}).items()))
            for rule in policy["spec"]["ingress"]
            for source in rule.get("from", [])
            if source.get("namespaceSelector", {}).get("matchLabels", {}).get(
                "kubernetes.io/metadata.name"
            )
            == "devai"
        }
        self.assertIn((("app.kubernetes.io/name", "devai-api"),), devai_selectors)
        self.assertIn((("app.kubernetes.io/name", "devai-api-worker"),), devai_selectors)

        devai = render_chart(
            "charts/apps/devai-api",
            "devai-api",
            "devai",
            ("values.yaml", "values-prod.yaml"),
        )
        pod = resource(devai, "Deployment", "devai-api")["spec"]["template"]["spec"]
        projected = next(volume for volume in pod["volumes"] if volume["name"] == "secret-service-token")
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
