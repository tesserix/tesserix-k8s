import json
import pathlib
import re
import subprocess
import sys
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
PROJECT_AUDIENCE = "387190457387450503"
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
    def test_registry_platform_seed_tracks_the_approved_gateway_resources(self):
        generated = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/generate-agentgateway-platform-resources.py"),
                "--check",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, generated.returncode, generated.stderr)

        documents = render_chart("charts/apps/agentgateway-route-sync")
        seed = resource(
            documents, "ConfigMap", "agentgateway-registry-platform-resources"
        )
        desired = json.loads(seed["data"]["resources.json"])

        self.assertEqual("List", desired["kind"])
        self.assertEqual(
            MIGRATED,
            {
                (item["kind"], item["metadata"]["name"])
                for item in desired["items"]
            },
        )
        self.assertTrue(
            all(
                item["metadata"]["namespace"] == "agentgateway-system"
                for item in desired["items"]
            )
        )

        policies = {
            item["metadata"]["name"]: item
            for item in desired["items"]
            if item["kind"] == "AgentgatewayPolicy"
        }
        for name, role in (
            ("mcp-public-oauth", "agentgateway.mcp"),
            ("ai-public-oauth", "agentgateway.models"),
        ):
            traffic = policies[name]["spec"]["traffic"]
            self.assertEqual(
                [PROJECT_AUDIENCE],
                traffic["jwtAuthentication"]["providers"][0]["audiences"],
            )
            self.assertEqual(
                [
                    f'"{role}" in jwt["urn:zitadel:iam:org:project:'
                    f'{PROJECT_AUDIENCE}:roles"]'
                ],
                traffic["authorization"]["policy"]["matchExpressions"],
            )

        job = resource(documents, "Job", "agentgateway-registry-platform-seed")
        pod_spec = job["spec"]["template"]["spec"]
        self.assertFalse(pod_spec["automountServiceAccountToken"])
        container = pod_spec["containers"][0]
        self.assertRegex(container["image"], r"@sha256:[0-9a-f]{64}$")
        script = container["args"][0]
        self.assertIn('/v0/agentgateway/import', script)
        self.assertIn('test "${count}" = "24"', script)
        count_pattern = re.search(
            r"grep -Ec '([^']+)' /seed/resources\.json", script
        )
        self.assertIsNotNone(count_pattern)
        count = subprocess.run(
            ["grep", "-Ec", count_pattern.group(1)],
            input=seed["data"]["resources.json"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, count.returncode, count.stderr)
        self.assertEqual("24", count.stdout.strip())
        self.assertTrue(
            any(
                env.get("valueFrom", {}).get("secretKeyRef", {}).get("name")
                == "agentgateway-route-sync-registry-key"
                for env in container["env"]
            )
        )

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
        self.assertIn(
            ("AgentgatewayBackend", "devai-vertex-api-key"), default_resources
        )
        self.assertIn(
            ("AgentgatewayBackend", "devai-vertex-api-key"), rollback_resources
        )

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
        apply_script = apply_container["args"][0]
        self.assertIn(
            "kubectl apply --dry-run=client -f /work/routes.yaml -o name",
            apply_script,
        )
        self.assertNotIn("awk '", apply_script)
        self.assertIn(
            {"name": "tmp", "mountPath": "/tmp"}, apply_container["volumeMounts"]
        )
        self.assertIn(
            {"name": "tmp", "emptyDir": {}}, pod_spec["volumes"]
        )

        handoff = resource(
            documents, "Job", "agentgateway-registry-ownership-handoff-v2"
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
        self.assertIn("2>/dev/null || true", script)

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
