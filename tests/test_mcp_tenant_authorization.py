"""MCP platform phases 3-5: per-server authorization, capability probing and
multi-tenant export, plus the mesh guardrails that carry them."""

import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
CHART = "charts/apps/agentgateway-route-sync"
PROBE_PRINCIPAL = "cluster.local/ns/agentgateway-system/sa/agentic-probe"


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


def resource(documents, kind, name):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


def istio_policies():
    result = subprocess.run(
        ["kubectl", "kustomize", str(ROOT / "manifests/agentic-istio")],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def values():
    return yaml.safe_load((ROOT / CHART / "values.yaml").read_text())


def render_script(documents):
    cronjob = resource(documents, "CronJob", "agentgateway-route-sync")
    pod = cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return pod["initContainers"][0]["args"][0]


class MultiTenantExportTests(unittest.TestCase):
    def test_route_sync_exports_every_tenant_namespace(self):
        script = render_script(render_chart(CHART))
        self.assertIn(
            f"namespace={','.join(values()['registry']['sourceNamespaces'])}",
            script,
        )

    def test_tenant_namespaces_are_configurable_without_editing_the_script(self):
        script = render_script(
            render_chart(CHART, "registry.sourceNamespaces={devai,acme}")
        )
        self.assertIn("namespace=devai,acme", script)

    def test_flat_path_stays_until_clients_have_migrated(self):
        self.assertTrue(values()["registry"]["legacyFlatPath"])
        self.assertIn("legacyFlatPath=true", render_script(render_chart(CHART)))

    def test_resource_floor_covers_the_platform_baseline(self):
        script = render_script(render_chart(CHART))
        floor = values()["registry"]["minDesiredResourceCount"]
        self.assertIn(f'test "${{expected_count}}" -ge "{floor}"', script)


class PerServerAuthorizationTests(unittest.TestCase):
    def test_scope_enforcement_is_requested_from_the_export(self):
        script = render_script(
            render_chart(CHART, "registry.requireServerScope=true")
        )
        self.assertIn("requireServerScope=true", script)
        self.assertIn(
            "scopeClaim=urn%3Azitadel%3Aiam%3Aorg%3Aproject%3A386889024519799084%3Aroles",
            script,
        )

    def test_scope_enforcement_ships_disabled_until_roles_exist(self):
        # Rendering the policies before Zitadel grants mcp:<tenant>:<server>
        # would 403 every existing client. The flag is the second step.
        self.assertFalse(values()["registry"]["requireServerScope"])
        self.assertIn(
            "requireServerScope=false", render_script(render_chart(CHART))
        )

    def test_scope_claim_matches_the_gateway_jwt_policy(self):
        self.assertEqual(
            values()["oauth"]["roleClaim"], values()["registry"]["scopeClaim"]
        )


class CapabilityProbeTests(unittest.TestCase):
    def setUp(self):
        self.documents = render_chart(CHART)
        self.cronjob = resource(self.documents, "CronJob", "agentic-probe")
        self.pod = self.cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"]

    def test_probe_runs_under_its_own_identity(self):
        self.assertEqual("agentic-probe", self.pod["serviceAccountName"])
        resource(self.documents, "ServiceAccount", "agentic-probe")

    def test_probe_dials_the_public_gateway_and_writes_only_status(self):
        container = self.pod["containers"][0]
        self.assertEqual(["/app/agentic-probe"], container["command"])
        env = {item["name"]: item for item in container["env"]}
        self.assertEqual(
            "http://agentgateway-mcp.agentgateway-system.svc.cluster.local:8080",
            env["GATEWAY_URL"]["value"],
        )
        self.assertEqual(
            ",".join(values()["registry"]["sourceNamespaces"]),
            env["TENANT_NAMESPACES"]["value"],
        )

    def test_probe_credentials_come_from_the_secret_store(self):
        container = self.pod["containers"][0]
        env = {item["name"]: item for item in container["env"]}
        for name in ("REGISTRY_DEPLOY_KEY", "MCP_CLIENT_ID", "MCP_CLIENT_SECRET"):
            self.assertIn("secretKeyRef", env[name]["valueFrom"])
        secret = resource(self.documents, "ExternalSecret", "agentic-probe-oauth")
        self.assertEqual(
            "ClusterSecretStore", secret["spec"]["secretStoreRef"]["kind"]
        )

    def test_probe_pod_is_hardened(self):
        self.assertTrue(self.pod["securityContext"]["runAsNonRoot"])
        container = self.pod["containers"][0]
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertEqual(["ALL"], container["securityContext"]["capabilities"]["drop"])

    def test_probe_can_be_disabled(self):
        documents = render_chart(CHART, "probe.enabled=false")
        names = {
            (document.get("kind"), document.get("metadata", {}).get("name"))
            for document in documents
        }
        self.assertNotIn(("CronJob", "agentic-probe"), names)


class ProbeMeshGuardrailTests(unittest.TestCase):
    def setUp(self):
        self.policies = istio_policies()

    def test_probe_may_read_the_catalog_and_write_only_observations(self):
        allow = resource(self.policies, "AuthorizationPolicy", "agentregistry-authz")
        rules = [
            rule
            for rule in allow["spec"]["rules"]
            if PROBE_PRINCIPAL
            in rule.get("from", [{}])[0].get("source", {}).get("principals", [])
        ]
        self.assertTrue(rules, "the prober needs an explicit ALLOW rule")
        operations = [
            operation for rule in rules for operation in rule.get("to", [])
        ]
        methods = {
            method
            for operation in operations
            for method in operation["operation"].get("methods", [])
        }
        paths = {
            path
            for operation in operations
            for path in operation["operation"].get("paths", [])
        }
        self.assertEqual({"GET", "PUT"}, methods)
        self.assertIn("/v0/mcpservers/*/status", paths)

    def test_probe_is_denied_every_other_registry_mutation(self):
        deny = resource(
            self.policies,
            "AuthorizationPolicy",
            "agentregistry-deny-writes-from-non-bootstrap",
        )
        baseline = next(
            rule
            for rule in deny["spec"]["rules"]
            if "notPrincipals" in rule["from"][0]["source"]
        )
        self.assertIn(
            PROBE_PRINCIPAL, baseline["from"][0]["source"]["notPrincipals"]
        )
        narrowed = next(
            rule
            for rule in deny["spec"]["rules"]
            if PROBE_PRINCIPAL
            in rule.get("from", [{}])[0].get("source", {}).get("principals", [])
        )
        operations = [item["operation"] for item in narrowed["to"]]
        self.assertIn(
            {
                "methods": ["PUT"],
                "notPaths": ["/v0/mcpservers/*/status"],
            },
            operations,
        )
        self.assertIn({"methods": ["POST", "PATCH", "DELETE"]}, operations)

    def test_probe_reaches_the_mcp_data_plane_only(self):
        allow = resource(self.policies, "AuthorizationPolicy", "agentgateway-authz")
        rule = next(
            rule
            for rule in allow["spec"]["rules"]
            if PROBE_PRINCIPAL
            in rule.get("from", [{}])[0].get("source", {}).get("principals", [])
        )
        self.assertEqual(["8080"], rule["to"][0]["operation"]["ports"])


if __name__ == "__main__":
    unittest.main()
