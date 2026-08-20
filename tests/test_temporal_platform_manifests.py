import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]


def load_yaml(path):
    return list(yaml.safe_load_all(path.read_text()))


def render_resources():
    result = subprocess.run(
        [
            "helm",
            "template",
            "temporal-platform-resources",
            str(ROOT / "charts/apps/temporal-platform-resources"),
            "--namespace",
            "temporal-system",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents, kind, name, namespace=None):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
        and (
            namespace is None
            or document.get("metadata", {}).get("namespace") == namespace
        )
    )


class TemporalPlatformManifestTests(unittest.TestCase):
    def test_official_chart_is_pinned_to_temporal_1_31_2(self):
        application = load_yaml(
            ROOT / "argocd/prod/infrastructure/temporal-platform.yaml"
        )[0]
        source = application["spec"]["source"]
        values = yaml.safe_load(source["helm"]["values"])

        self.assertEqual("https://github.com/temporalio/helm-charts", source["repoURL"])
        self.assertEqual("9f4d328c31c77c323d272d0c5f615cf02bd46dab", source["targetRevision"])
        self.assertEqual("charts/temporal", source["path"])
        self.assertEqual("1.31.2", values["server"]["image"]["tag"])
        self.assertEqual(
            "asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/third-party/temporal-server",
            values["server"]["image"]["repository"],
        )
        self.assertFalse(values["web"]["enabled"])
        self.assertFalse(values["admintools"]["enabled"])

    def test_server_is_ha_observable_and_hardened(self):
        application = load_yaml(
            ROOT / "argocd/prod/infrastructure/temporal-platform.yaml"
        )[0]
        values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
        server = values["server"]

        self.assertEqual(3, server["replicaCount"])
        self.assertTrue(server["metrics"]["serviceMonitor"]["enabled"])
        self.assertEqual(90, server["terminationGracePeriodSeconds"])
        self.assertFalse(values["serviceAccount"]["create"])
        self.assertEqual("temporal-platform", values["serviceAccount"]["name"])

        for component in ("frontend", "history", "matching", "worker"):
            component_values = server[component]
            self.assertEqual(3, component_values["replicaCount"])
            self.assertEqual(2, component_values["podDisruptionBudget"]["minAvailable"])
            topology_keys = {
                constraint["topologyKey"]
                for constraint in component_values["topologySpreadConstraints"]
            }
            self.assertEqual(
                {"kubernetes.io/hostname", "topology.kubernetes.io/zone"},
                topology_keys,
            )
            security = component_values["containerSecurityContext"]
            self.assertFalse(security["allowPrivilegeEscalation"])
            self.assertTrue(security["readOnlyRootFilesystem"])
            self.assertEqual(["ALL"], security["capabilities"]["drop"])

    def test_postgres_visibility_is_declarative_and_encrypted(self):
        application = load_yaml(
            ROOT / "argocd/prod/infrastructure/temporal-platform.yaml"
        )[0]
        values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
        persistence = values["server"]["config"]["persistence"]

        self.assertEqual("default", persistence["defaultStore"])
        self.assertEqual("visibility", persistence["visibilityStore"])
        expected = {
            "default": "temporal_platform",
            "visibility": "temporal_platform_visibility",
        }
        for store, database in expected.items():
            sql = persistence["datastores"][store]["sql"]
            self.assertEqual(database, sql["databaseName"])
            self.assertEqual("postgres12", sql["pluginName"])
            self.assertEqual(
                "infra-postgres-rw.infra.svc.cluster.local:5432",
                sql["connectAddr"],
            )
            self.assertFalse(sql["createDatabase"])
            self.assertTrue(sql["manageSchema"])
            self.assertTrue(sql["tls"]["enabled"])

    def test_product_namespaces_are_explicit(self):
        application = load_yaml(
            ROOT / "argocd/prod/infrastructure/temporal-platform.yaml"
        )[0]
        values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
        namespaces = {
            entry["name"]
            for entry in values["server"]["config"]["namespaces"]["namespace"]
        }
        self.assertEqual(
            {
                "agentic-registry",
                "devai",
                "dwellm8",
                "homechef",
                "kora",
                "mark8ly",
                "postiz",
            },
            namespaces,
        )

    def test_resources_create_retained_databases_and_private_access(self):
        documents = render_resources()
        namespace = resource(documents, "Namespace", "temporal-system")
        self.assertEqual(
            "ambient", namespace["metadata"]["labels"]["istio.io/dataplane-mode"]
        )

        for name in ("temporal-platform", "temporal-platform-visibility"):
            database = resource(documents, "Database", name, "infra")
            self.assertEqual("infra-postgres", database["spec"]["cluster"]["name"])
            self.assertEqual("temporal", database["spec"]["owner"])
            self.assertEqual("retain", database["spec"]["databaseReclaimPolicy"])

        service_account = resource(
            documents, "ServiceAccount", "temporal-platform", "temporal-system"
        )
        self.assertFalse(service_account["automountServiceAccountToken"])

        ingress = resource(
            documents,
            "NetworkPolicy",
            "temporal-platform-frontend-ingress",
            "temporal-system",
        )
        peers = {
            peer["namespaceSelector"]["matchLabels"][
                "kubernetes.io/metadata.name"
            ]
            for rule in ingress["spec"]["ingress"]
            for peer in rule["from"]
        }
        self.assertEqual(
            {
                "agentregistry-system",
                "devai",
                "dwellm8",
                "homechef",
                "kora",
                "mark8ly",
                "postiz",
            },
            peers,
        )
        self.assertEqual(
            [7233],
            [port["port"] for port in ingress["spec"]["ingress"][0]["ports"]],
        )

    def test_alerts_cover_availability_persistence_and_failures(self):
        documents = render_resources()
        rule = resource(
            documents,
            "PrometheusRule",
            "temporal-platform",
            "temporal-system",
        )
        alerts = {
            item["alert"]
            for group in rule["spec"]["groups"]
            for item in group["rules"]
        }
        self.assertEqual(
            {
                "TemporalDeploymentUnavailable",
                "TemporalPersistenceErrors",
                "TemporalServiceErrorRateHigh",
                "TemporalWorkflowFailures",
            },
            alerts,
        )


if __name__ == "__main__":
    unittest.main()
