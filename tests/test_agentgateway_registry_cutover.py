import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
MIGRATED = {
    ("AgentgatewayBackend", "ai-zitadel-jwks"),
    ("AgentgatewayBackend", "devai-anthropic"),
    ("AgentgatewayBackend", "devai-gemini"),
    ("AgentgatewayBackend", "devai-groq"),
    ("AgentgatewayBackend", "devai-nemoclaw"),
    ("AgentgatewayBackend", "devai-openai"),
    ("AgentgatewayBackend", "devai-openrouter"),
    ("AgentgatewayBackend", "devai-vertex"),
    ("AgentgatewayBackend", "kora-conversation-providers"),
    ("AgentgatewayBackend", "kora-embedding-providers"),
    ("AgentgatewayBackend", "kora-structured-providers"),
    ("AgentgatewayBackend", "mcp-zitadel-jwks"),
    ("AgentgatewayPolicy", "ai-public-oauth"),
    ("AgentgatewayPolicy", "ai-public-observability"),
    ("AgentgatewayPolicy", "devai-ai-observability"),
    ("AgentgatewayPolicy", "devai-ai-routes"),
    ("AgentgatewayPolicy", "devai-ai-traffic"),
    ("AgentgatewayPolicy", "kora-ai-guardrails"),
    ("AgentgatewayPolicy", "kora-ai-observability"),
    ("AgentgatewayPolicy", "kora-ai-traffic"),
    ("AgentgatewayPolicy", "mcp-public-oauth"),
    ("AgentgatewayPolicy", "mcp-public-observability"),
    ("HTTPRoute", "devai-ai"),
    ("HTTPRoute", "kora-ai"),
}


def render_chart(chart, *set_values):
    command = [
        "helm",
        "template",
        "test",
        str(ROOT / chart),
        "--namespace",
        "agentgateway-system",
    ]
    for value in set_values:
        command.extend(["--set", value])
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resources(documents):
    return {
        (document.get("kind"), document.get("metadata", {}).get("name"))
        for document in documents
    }


def resource(documents, kind, name):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


class AgentGatewayRegistryCutoverTests(unittest.TestCase):
    def test_registry_is_the_default_owner_and_helm_is_a_tested_rollback(self):
        charts = (
            "charts/apps/devai-ai-gateway",
            "charts/apps/kora-ai-gateway",
            "charts/apps/agentgateway-route-sync",
        )
        default_resources = set()
        rollback_resources = set()
        for chart in charts:
            default_resources |= resources(render_chart(chart))
            rollback_resources |= resources(
                render_chart(chart, "registryOwnership.enabled=false")
            )

        self.assertFalse(default_resources & MIGRATED)
        self.assertEqual(MIGRATED, rollback_resources & MIGRATED)

    def test_route_sync_pruning_and_handoff_fail_closed(self):
        documents = render_chart("charts/apps/agentgateway-route-sync")
        values = yaml.safe_load(
            (ROOT / "charts/apps/agentgateway-route-sync/values.yaml").read_text()
        )

        self.assertTrue(values["registry"]["prune"])
        self.assertEqual(24, values["registry"]["minDesiredResourceCount"])
        self.assertFalse(values["migrationImport"]["enabled"])
        self.assertTrue(values["ownershipHandoff"]["enabled"])

        cronjob = resource(documents, "CronJob", "agentgateway-route-sync")
        pod_spec = cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        render_script = pod_spec["initContainers"][0]["args"][0]
        self.assertIn('test "${expected_count}" -ge "24"', render_script)
        apply_container = pod_spec["containers"][0]
        self.assertIn(
            {"name": "tmp", "mountPath": "/tmp"}, apply_container["volumeMounts"]
        )
        self.assertIn(
            {"name": "tmp", "emptyDir": {}}, pod_spec["volumes"]
        )

        handoff = resource(
            documents, "Job", "agentgateway-registry-ownership-handoff-v1"
        )
        script = handoff["spec"]["template"]["spec"]["containers"][0]["args"][0]
        resource_names = {
            "AgentgatewayBackend": "agentgatewaybackends.agentgateway.dev",
            "AgentgatewayPolicy": "agentgatewaypolicies.agentgateway.dev",
            "HTTPRoute": "httproutes.gateway.networking.k8s.io",
        }
        for kind, name in MIGRATED:
            self.assertEqual(2, script.count(f"{resource_names[kind]} {name}\n"))
        self.assertIn("managed-by", script)
        self.assertIn("argocd.argoproj.io/tracking-id-", script)

    def test_import_guard_counts_objects_and_requires_exact_scope(self):
        documents = render_chart(
            "charts/apps/agentgateway-route-sync",
            "migrationImport.enabled=true",
            "ownershipHandoff.enabled=false",
        )
        job = resource(documents, "Job", "agentgateway-registry-import-v1")
        script = job["spec"]["template"]["spec"]["initContainers"][0]["args"][0]
        self.assertIn("--output name", script)
        self.assertIn('test "${count}" = "24"', script)


if __name__ == "__main__":
    unittest.main()
