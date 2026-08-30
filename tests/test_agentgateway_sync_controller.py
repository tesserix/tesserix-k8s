import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
CHART = ROOT / "charts/apps/agentgateway-route-sync"


def render_chart(*set_values):
    command = [
        "helm",
        "template",
        "test",
        str(CHART),
        "--namespace",
        "agentgateway-system",
    ]
    for value in set_values:
        command.extend(["--set", value])
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents, kind, name):
    for document in documents:
        if document.get("kind") == kind and document.get("metadata", {}).get("name") == name:
            return document
    raise AssertionError(f"missing {kind}/{name}")


class AgentGatewaySyncControllerTests(unittest.TestCase):
    def test_shadow_controller_is_ha_observable_and_incapable_of_pruning(self):
        documents = render_chart()
        deployment = resource(documents, "Deployment", "agentgateway-route-sync-controller")
        pod = deployment["spec"]["template"]["spec"]
        container = pod["containers"][0]
        env = {item["name"]: item for item in container["env"]}

        self.assertEqual(2, deployment["spec"]["replicas"])
        self.assertEqual("agentgateway-route-sync", pod["serviceAccountName"])
        self.assertEqual(["/app/agentgateway-sync"], container["command"])
        self.assertRegex(
            container["image"],
            r"^asia-south1-docker\.pkg\.dev/tesseracthub-480811/ghcr-remote/"
            r"tesserix/agentic-registry@sha256:[0-9a-f]{64}$",
        )
        self.assertEqual("shadow", env["RECONCILIATION_MODE"]["value"])
        self.assertEqual("true", env["PRUNE"]["value"])
        self.assertEqual("27", env["MIN_RESOURCES"]["value"])
        self.assertEqual("5242880", env["MAX_BODY_BYTES"]["value"])
        self.assertIn("/v0/export/agentgateway?", env["REGISTRY_URL"]["value"])
        self.assertIn("namespace=devai", env["REGISTRY_URL"]["value"])
        self.assertEqual("/var/run/secrets/registry/API_KEY", env["REGISTRY_TOKEN_FILE"]["value"])
        self.assertEqual({"http"}, {port["name"] for port in container["ports"]})
        self.assertEqual("/healthz", container["livenessProbe"]["httpGet"]["path"])
        self.assertEqual("/readyz", container["readinessProbe"]["httpGet"]["path"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertEqual(["ALL"], container["securityContext"]["capabilities"]["drop"])
        self.assertNotIn("cpu", container["resources"]["requests"])
        self.assertNotIn("cpu", container["resources"]["limits"])
        self.assertEqual(
            {"kubernetes.io/hostname", "topology.kubernetes.io/zone"},
            {constraint["topologyKey"] for constraint in pod["topologySpreadConstraints"]},
        )
        self.assertEqual(1, resource(documents, "PodDisruptionBudget", "agentgateway-route-sync-controller")["spec"]["minAvailable"])
        self.assertFalse(resource(documents, "CronJob", "agentgateway-route-sync")["spec"]["suspend"])

        role = resource(documents, "Role", "agentgateway-route-sync")
        lease_rules = [
            rule
            for rule in role["rules"]
            if rule.get("apiGroups") == ["coordination.k8s.io"]
            and rule.get("resources") == ["leases"]
        ]
        self.assertTrue(any(rule.get("verbs") == ["create"] for rule in lease_rules))
        self.assertTrue(
            any(
                rule.get("resourceNames") == ["agentgateway-route-sync"]
                and {"get", "update", "patch"}.issubset(rule.get("verbs", []))
                and "create" not in rule.get("verbs", [])
                for rule in lease_rules
            )
        )
        resource(documents, "PodMonitoring", "agentgateway-route-sync-controller")
        alerts = resource(documents, "Rules", "agentgateway-route-sync-controller")
        self.assertEqual("1m", alerts["spec"]["groups"][0]["interval"])
        alert_names = {
            rule["alert"]
            for group in alerts["spec"]["groups"]
            for rule in group["rules"]
            if "alert" in rule
        }
        self.assertTrue(
            {
                "AgentGatewaySyncRegistryStale",
                "AgentGatewaySyncReconcileStale",
                "AgentGatewaySyncDrift",
                "AgentGatewaySyncLeaderUnavailable",
            }.issubset(alert_names)
        )

    def test_active_cutover_suspends_but_does_not_delete_cron_rollback(self):
        documents = render_chart("controller.mode=active", "cron.suspend=true")
        deployment = resource(documents, "Deployment", "agentgateway-route-sync-controller")
        env = {
            item["name"]: item["value"]
            for item in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
            if "value" in item
        }
        self.assertEqual("active", env["RECONCILIATION_MODE"])
        self.assertTrue(resource(documents, "CronJob", "agentgateway-route-sync")["spec"]["suspend"])

    def test_controller_rejects_a_mutable_image_reference(self):
        with self.assertRaises(subprocess.CalledProcessError):
            render_chart("controller.image.digest=latest")

    def test_active_controller_requires_the_cron_writer_to_be_suspended(self):
        with self.assertRaises(subprocess.CalledProcessError):
            render_chart("controller.mode=active")

    def test_suspended_cron_requires_the_controller_to_be_active(self):
        with self.assertRaises(subprocess.CalledProcessError):
            render_chart("cron.suspend=true")

    def test_controller_rejects_an_unknown_reconciliation_mode(self):
        with self.assertRaises(subprocess.CalledProcessError):
            render_chart("controller.mode=writer")


if __name__ == "__main__":
    unittest.main()
