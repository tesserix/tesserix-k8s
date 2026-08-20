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

    def test_namespace_bootstrap_is_a_rerunnable_presync_hook(self):
        application = load_yaml(
            ROOT / "argocd/prod/infrastructure/temporal-platform.yaml"
        )[0]
        values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])

        self.assertEqual(
            {
                "argocd.argoproj.io/hook": "PreSync",
                "argocd.argoproj.io/hook-delete-policy": "BeforeHookCreation",
            },
            values["schema"]["jobAnnotations"],
        )

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
        values = load_yaml(
            ROOT / "charts/apps/temporal-platform-resources/values.yaml"
        )[0]
        namespaces = {entry["name"] for entry in values["temporalNamespaces"]}
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

    def test_ambient_hbone_network_path_is_allowed(self):
        documents = render_resources()
        hbone = resource(
            documents,
            "NetworkPolicy",
            "temporal-platform-hbone",
            "temporal-system",
        )

        self.assertEqual(["Ingress", "Egress"], hbone["spec"]["policyTypes"])
        self.assertEqual(
            "10.20.0.0/16",
            hbone["spec"]["ingress"][0]["from"][0]["ipBlock"]["cidr"],
        )
        self.assertEqual(
            [15008],
            [port["port"] for port in hbone["spec"]["ingress"][0]["ports"]],
        )
        self.assertEqual(
            "10.20.0.0/16",
            hbone["spec"]["egress"][0]["to"][0]["ipBlock"]["cidr"],
        )
        self.assertEqual(
            [15008],
            [port["port"] for port in hbone["spec"]["egress"][0]["ports"]],
        )

        internal = resource(
            documents,
            "NetworkPolicy",
            "temporal-platform-internal",
            "temporal-system",
        )
        ingress_namespaces = {
            peer["namespaceSelector"]["matchLabels"][
                "kubernetes.io/metadata.name"
            ]
            for rule in internal["spec"]["ingress"]
            for peer in rule["from"]
            if "namespaceSelector" in peer
        }
        self.assertIn("istio-system", ingress_namespaces)

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


class TemporalClientEgressTests(unittest.TestCase):
    """The frontend ingress policy naming a namespace is only half the path:
    that namespace's own egress policy has to allow temporal-system too, or the
    worker's gRPC dial dies as a transport error with nothing in either log."""

    def render_istio_config(self):
        result = subprocess.run(
            [
                "helm",
                "template",
                "istio-config",
                str(ROOT / "charts/thirdparty/istio-config"),
                "--namespace",
                "istio-system",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return [
            document
            for document in yaml.safe_load_all(result.stdout)
            if document
        ]

    def egress_namespaces(self, documents, name, namespace):
        policy = resource(documents, "NetworkPolicy", name, namespace)
        return {
            peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
            for rule in policy["spec"].get("egress", [])
            for peer in rule.get("to", [])
            if "namespaceSelector" in peer
        }

    def test_every_temporal_client_namespace_may_egress_to_it(self):
        istio = self.render_istio_config()
        temporal = render_resources()
        ingress = resource(
            temporal,
            "NetworkPolicy",
            "temporal-platform-frontend-ingress",
            "temporal-system",
        )
        clients = {
            peer["namespaceSelector"]["matchLabels"][
                "kubernetes.io/metadata.name"
            ]
            for rule in ingress["spec"]["ingress"]
            for peer in rule["from"]
            if "namespaceSelector" in peer
        }

        for client in sorted(clients):
            with self.subTest(namespace=client):
                try:
                    allowed = self.egress_namespaces(
                        istio, f"allow-{client}-egress", client
                    )
                except StopIteration:
                    continue  # namespace has no restrictive egress policy
                self.assertIn("temporal-system", allowed)


class TemporalNamespaceRegistrationTests(unittest.TestCase):
    """The upstream chart registers namespaces with a one-shot Job that cannot
    retry: when it raced the frontend's first start it exhausted its backoff and
    left every namespace unregistered, which crashlooped both Temporal's own
    worker and every client worker. Registration is a sync hook here instead, so
    it re-runs until it succeeds."""

    def setUp(self):
        self.documents = render_resources()
        self.job = resource(
            self.documents, "Job", "temporal-namespace-register", "temporal-system"
        )
        self.script = self.job["spec"]["template"]["spec"]["containers"][0]["args"][0]

    def test_registration_reruns_on_every_sync(self):
        annotations = self.job["metadata"]["annotations"]
        self.assertEqual("PostSync", annotations["argocd.argoproj.io/hook"])
        self.assertEqual(
            "BeforeHookCreation",
            annotations["argocd.argoproj.io/hook-delete-policy"],
        )

    def test_every_declared_namespace_is_registered_with_its_retention(self):
        values = load_yaml(
            ROOT / "charts/apps/temporal-platform-resources/values.yaml"
        )[0]
        declared = values["temporalNamespaces"]
        self.assertTrue(declared)
        for entry in declared:
            with self.subTest(namespace=entry["name"]):
                self.assertIn(
                    f"{entry['name']}:{entry['retention']}", self.script
                )

    def test_registering_an_existing_namespace_is_not_a_failure(self):
        # The hook runs on every sync, so the second run always finds the
        # namespaces already there.
        self.assertIn("already exists", self.script)

    def test_upstream_chart_no_longer_owns_registration(self):
        application = load_yaml(
            ROOT / "argocd/prod/infrastructure/temporal-platform.yaml"
        )[0]
        values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
        self.assertFalse(values["server"]["config"]["namespaces"]["create"])

    def test_the_namespace_list_lives_in_one_place(self):
        application = load_yaml(
            ROOT / "argocd/prod/infrastructure/temporal-platform.yaml"
        )[0]
        values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
        self.assertNotIn("namespace", values["server"]["config"]["namespaces"])
