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
        self.assertEqual("agentgateway", gateway["spec"]["gatewayClassName"])

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
        self.assertEqual({"prod-devai-anthropic-api-key"}, remote_refs)

        backends = [
            document
            for document in documents
            if document.get("kind") == "AgentgatewayBackend"
        ]
        provider_names = {
            provider["name"]
            for backend in backends
            for group in backend["spec"]["ai"]["groups"]
            for provider in group["providers"]
        }
        self.assertNotIn("xai", provider_names)

    def test_gateway_only_accepts_kora_api_clients(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        policy = resource(documents, "NetworkPolicy", "kora-ai")
        client = policy["spec"]["ingress"][0]["from"][0]

        self.assertEqual(
            "kora",
            client["namespaceSelector"]["matchLabels"][
                "kubernetes.io/metadata.name"
            ],
        )
        self.assertEqual(
            "kora-api",
            client["podSelector"]["matchLabels"]["app.kubernetes.io/name"],
        )

        agent_client = policy["spec"]["ingress"][1]["from"][0]
        self.assertEqual(
            "kora-ai-agents",
            agent_client["podSelector"]["matchLabels"]["app.kubernetes.io/name"],
        )

    def test_gateway_listener_requires_the_kora_workload_identity(self):
        documents = render_chart(
            "charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system"
        )
        policy = resource(documents, "AuthorizationPolicy", "kora-ai")

        client_rule = policy["spec"]["rules"][0]
        self.assertEqual(
            ["cluster.local/ns/kora/sa/kora-api"],
            client_rule["from"][0]["source"]["principals"],
        )
        self.assertEqual(["8080"], client_rule["to"][0]["operation"]["ports"])

        self.assertEqual(
            ["cluster.local/ns/kora/sa/kora-ai-agents"],
            policy["spec"]["rules"][1]["from"][0]["source"]["principals"],
        )

    def test_kora_gets_only_a_client_key_and_narrow_gateway_egress(self):
        documents = render_chart("charts/apps/kora-api", "kora", "kora")
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

    def test_ai_agents_are_non_root_bounded_and_gateway_only(self):
        documents = render_chart("charts/apps/kora-ai-agents", "kora-ai-agents", "kora")
        deployment = resource(documents, "Deployment", "kora-ai-agents")
        external_secret = resource(documents, "ExternalSecret", "kora-ai-agents")
        network_policy = resource(documents, "NetworkPolicy", "kora-ai-agents")

        pod = deployment["spec"]["template"]["spec"]
        container = pod["containers"][0]
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


if __name__ == "__main__":
    unittest.main()
