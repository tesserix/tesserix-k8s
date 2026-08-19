import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]


def render_chart(chart: str, release: str, namespace: str) -> list[dict]:
    result = subprocess.run(
        ["helm", "template", release, str(ROOT / chart), "--namespace", namespace],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents: list[dict], kind: str, name: str) -> dict:
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


class KagentSubstrateGatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.documents = render_chart(
            "charts/apps/kagent-agent-sync", "kagent-agent-sync", "kagent-system"
        )

    def test_registry_sync_targets_substrate_and_reconciles_both_runtime_kinds(self):
        cronjob = resource(self.documents, "CronJob", "kagent-agent-sync")
        pod = cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        render_script = pod["initContainers"][0]["args"][0]
        apply_script = pod["containers"][0]["args"][0]

        self.assertIn("workerPool=kagent-default", render_script)
        self.assertIn(
            "gatewayUrl=http%3A%2F%2Fagentgateway-mcp.agentgateway-system.svc.cluster.local%3A8080",
            render_script,
        )
        self.assertIn("sandboxagents.kagent.dev", apply_script)
        self.assertIn("remotemcpservers.kagent.dev", apply_script)
        self.assertIn(
            "--prune-allowlist=kagent.dev/v1alpha2/SandboxAgent", apply_script
        )
        self.assertIn(
            "--prune-allowlist=kagent.dev/v1alpha2/RemoteMCPServer", apply_script
        )

        role = resource(self.documents, "Role", "kagent-agent-sync")
        self.assertIn("sandboxagents", role["rules"][0]["resources"])
        self.assertIn("remotemcpservers", role["rules"][0]["resources"])

    def test_model_configs_send_anthropic_and_openai_through_agentgateway(self):
        configs = {
            document["metadata"]["name"]: document
            for document in self.documents
            if document.get("kind") == "ModelConfig"
        }
        self.assertEqual(
            "http://ai-gateway.agentgateway-system.svc.cluster.local:8080/anthropic",
            configs["kagent-mc-anthropic"]["spec"]["anthropic"]["baseUrl"],
        )
        self.assertEqual(
            "http://ai-gateway.agentgateway-system.svc.cluster.local:8080/openai/v1",
            configs["kagent-mc-openai"]["spec"]["openAI"]["baseUrl"],
        )
        self.assertTrue(configs["kagent-mc-anthropic"]["spec"]["apiKeyPassthrough"])
        self.assertTrue(configs["kagent-mc-openai"]["spec"]["apiKeyPassthrough"])

    def test_gitops_canary_exercises_the_gvisor_worker_without_a_stored_key(self):
        canary = resource(self.documents, "SandboxAgent", "devai-substrate-canary")
        self.assertEqual("substrate", canary["spec"]["platform"])
        self.assertEqual(
            {"name": "kagent-default"}, canary["spec"]["substrate"]["workerPoolRef"]
        )
        self.assertEqual(
            "kagent-mc-openai", canary["spec"]["declarative"]["modelConfig"]
        )
        self.assertNotIn("apiKeySecret", canary["spec"])


if __name__ == "__main__":
    unittest.main()
