import pathlib
import subprocess
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
STORE = "openbao-civiclens-production"


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def load_all(path):
    return [d for d in yaml.safe_load_all((ROOT / path).read_text()) if d]


def render(chart, *args):
    out = subprocess.check_output(
        ["helm", "template", chart.rsplit("/", 1)[1], f"charts/{chart}", *args], cwd=ROOT, text=True
    )
    return [d for d in yaml.safe_load_all(out) if d]


def named(resources, kind):
    return {r["metadata"]["name"]: r for r in resources if r["kind"] == kind}


class CivicLensSecretWatch(unittest.TestCase):
    def test_cnpg_observes_created_and_rotated_password_secrets(self):
        resources = named(load_all("external-secrets/prod/global/externalsecret.yaml"), "ExternalSecret")
        for role in ("runtime", "migrator"):
            template = resources[f"global-postgres-civiclens-{role}"]["spec"]["target"]["template"]
            self.assertEqual(template.get("metadata", {}).get("labels", {}).get("cnpg.io/reload"), "true")


class CivicLensApiChart(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.resources = render(
            "apps/civiclens-api",
            "--namespace", "civiclens",
            "--set", "image.digest=sha256:" + "a" * 64,
        )

    def test_runtime_and_migration_read_separate_openbao_secrets(self):
        secrets = named(self.resources, "ExternalSecret")
        runtime = secrets["civiclens-api-config"]["spec"]
        migration = secrets["civiclens-migration-config"]["spec"]
        for spec in (runtime, migration):
            self.assertEqual(spec["secretStoreRef"], {"name": STORE, "kind": "SecretStore"})
        self.assertEqual(
            {d["remoteRef"]["key"] for d in runtime["data"]},
            {"civiclens/prod/app/civiclens-db-runtime-password",
             "civiclens/prod/app/civiclens-identity-key",
             "civiclens/prod/app/civiclens-ai-gateway-key"},
        )
        self.assertEqual(
            {d["remoteRef"]["key"] for d in migration["data"]},
            {"civiclens/prod/app/civiclens-db-migrator-password"},
        )
        runtime_json = runtime["target"]["template"]["data"]["secrets.json"]
        migration_json = migration["target"]["template"]["data"]["secrets.json"]
        self.assertIn("//civiclens_runtime:", runtime_json)
        self.assertIn("//civiclens_migrator:", migration_json)
        for doc in (runtime_json, migration_json):
            self.assertIn("@global-postgres-rw.global.svc.cluster.local:5432/civiclens_db", doc)
            self.assertIn("sslmode=verify-full", doc)

    def test_api_runs_with_runtime_credentials_and_verified_database_tls(self):
        deployment = named(self.resources, "Deployment")["civiclens-api"]
        pod = deployment["spec"]["template"]["spec"]
        self.assertEqual(
            deployment["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"],
            "civiclens-api",
        )
        self.assertFalse(pod["automountServiceAccountToken"])
        container = pod["containers"][0]
        self.assertTrue(container["image"].endswith("/civiclens-api@sha256:" + "a" * 64))
        env = {e["name"]: e.get("value") for e in container["env"]}
        self.assertEqual(env["CIVICLENS_ENV"], "production")
        self.assertEqual(env["CIVICLENS_BIND"], "0.0.0.0:8080")
        self.assertEqual(env["CIVICLENS_OIDC_ORGANIZATION_ID"], "consumer-civiclens")
        self.assertEqual(env["CIVICLENS_PUBLISHING_ENABLED"], "false")
        mounts = {m["mountPath"]: m["name"] for m in container["volumeMounts"]}
        self.assertEqual(env["CIVICLENS_SECRETS_FILE"].rsplit("/", 1)[0], next(
            p for p, n in mounts.items() if n == "config"))
        self.assertEqual(env["PGSSLROOTCERT"].rsplit("/", 1)[0], next(
            p for p, n in mounts.items() if n == "postgres-ca"))
        volumes = {v["name"]: v["secret"]["secretName"] for v in pod["volumes"]}
        self.assertEqual(volumes, {"config": "civiclens-api-config",
                                   "postgres-ca": "global-postgres-ca"})
        self.assertNotIn("cpu", container["resources"].get("limits", {}))
        self.assertNotIn("cpu", container["resources"].get("requests", {}))
        self.assertEqual(container["readinessProbe"]["httpGet"]["path"], "/readyz")
        self.assertEqual(deployment["metadata"]["annotations"]["reloader.stakater.com/auto"], "true")

    def test_migration_hook_runs_the_same_image_with_owner_credentials_only(self):
        job = named(self.resources, "Job")["civiclens-api-migrate"]
        annotations = job["metadata"]["annotations"]
        self.assertEqual(annotations["argocd.argoproj.io/hook"], "Sync")
        self.assertEqual(annotations["argocd.argoproj.io/sync-wave"], "-1")
        pod = job["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        [container] = pod["containers"]
        self.assertEqual(container["args"], ["migrate"])
        deployment = named(self.resources, "Deployment")["civiclens-api"]
        self.assertEqual(container["image"], deployment["spec"]["template"]["spec"]["containers"][0]["image"])
        secrets = {v["secret"]["secretName"] for v in pod["volumes"]}
        self.assertEqual(secrets, {"civiclens-migration-config", "global-postgres-ca"})

    def test_tag_is_used_when_kargo_has_not_set_a_digest(self):
        resources = render("apps/civiclens-api", "--set", "image.digest=",
                           "--set", "image.tag=deploy-90a2774")
        image = named(resources, "Deployment")["civiclens-api"]["spec"]["template"]["spec"]["containers"][0]["image"]
        self.assertTrue(image.endswith("/civiclens-api:deploy-90a2774"))

    def test_default_values_pin_a_verified_digest_before_first_promotion(self):
        resources = render("apps/civiclens-api")
        image = named(resources, "Deployment")["civiclens-api"]["spec"]["template"]["spec"]["containers"][0]["image"]
        self.assertRegex(image, r"/global/civiclens-api@sha256:[0-9a-f]{64}$")


class CivicLensDelivery(unittest.TestCase):
    def test_api_application_is_kargo_authorized_and_registered(self):
        app = load("argocd/prod/apps/civiclens/civiclens-api.yaml")
        self.assertEqual(app["metadata"]["annotations"]["kargo.akuity.io/authorized-stage"],
                         "kargo-civiclens:prod")
        self.assertEqual(app["spec"]["project"], "civiclens")
        self.assertEqual(app["spec"]["source"]["repoURL"], "https://github.com/tesserix/tesserix-k8s.git")
        self.assertEqual(app["spec"]["source"]["path"], "charts/apps/civiclens-api")
        self.assertEqual(app["spec"]["destination"]["namespace"], "civiclens")
        self.assertEqual(set(load("argocd/prod/apps/civiclens/kustomization.yaml")["resources"]),
                         {"civiclens-api.yaml", "civiclens-ai-gateway.yaml", "civiclens-istio.yaml"})
        self.assertIn("civiclens-app-of-apps.yaml", load("argocd/prod/apps/kustomization.yaml")["resources"])
        self.assertIn("civiclens.yaml", load("argocd/prod/projects/kustomization.yaml")["resources"])

    def test_parent_does_not_revert_kargo_image_parameters(self):
        parent = load("argocd/prod/apps/civiclens-app-of-apps.yaml")
        self.assertEqual(parent["spec"]["source"]["path"], "argocd/prod/apps/civiclens")
        self.assertIn("/spec/source/helm/parameters", parent["spec"]["ignoreDifferences"][0]["jsonPointers"])
        self.assertIn("RespectIgnoreDifferences=true", parent["spec"]["syncPolicy"]["syncOptions"])

    def test_kargo_project_can_read_tesserix_k8s(self):
        kustomization = load("external-secrets/prod/kustomization.yaml")["resources"]
        self.assertIn("kargo-civiclens", kustomization)
        [creds] = load_all("external-secrets/prod/kargo-civiclens/tesserix-k8s-git-externalsecret.yaml")
        self.assertEqual(creds["metadata"]["namespace"], "kargo-civiclens")
        template = creds["spec"]["target"]["template"]
        self.assertEqual(template["metadata"]["labels"]["kargo.akuity.io/cred-type"], "git")
        self.assertEqual(template["data"]["repoURL"], "https://github.com/tesserix/tesserix-k8s.git")


class CivicLensSecrets(unittest.TestCase):
    def test_each_namespace_reader_is_bound_to_its_own_policy(self):
        self.assertIn("civiclens-openbao-readers.yaml",
                      load("external-secrets/prod/kustomization.yaml")["resources"])
        stores = {d["metadata"]["namespace"]: d
                  for d in load_all("external-secrets/prod/civiclens-openbao-readers.yaml")
                  if d["kind"] == "SecretStore"}
        self.assertEqual(set(stores), {"civiclens", "global", "agentgateway-system"})
        bootstrap = load("charts/thirdparty/openbao/values.yaml")["bootstrap"]
        policies = {p["name"]: p["hcl"] for p in bootstrap["policies"]}
        roles = {r["name"]: r for r in bootstrap["kubernetesRoles"]}
        expected = {
            "civiclens": {"civiclens-db-runtime-password", "civiclens-db-migrator-password",
                          "civiclens-identity-key", "civiclens-ai-gateway-key"},
            "global": {"civiclens-db-runtime-password", "civiclens-db-migrator-password"},
            "agentgateway-system": {"civiclens-ai-gateway-key"},
        }
        for namespace, names in expected.items():
            store = stores[namespace]
            self.assertEqual(store["metadata"]["name"], STORE)
            auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
            role = f"read-civiclens-{namespace}-production"
            self.assertEqual(auth["role"], role)
            self.assertEqual(auth["serviceAccountRef"]["name"], "civiclens-production-reader")
            self.assertEqual(roles[role]["namespaces"], [namespace])
            self.assertEqual(roles[role]["serviceAccounts"], ["civiclens-production-reader"])
            self.assertEqual(roles[role]["policies"], [role])
            paths = {line.split('"')[1] for line in policies[role].splitlines() if line.strip()}
            self.assertEqual(paths, {f"kv/data/civiclens/prod/app/{n}" for n in names})
            self.assertNotIn("update", policies[role])

    def test_cnpg_password_secrets_come_from_the_global_reader(self):
        secrets = {d["metadata"]["name"]: d
                   for d in load_all("external-secrets/prod/global/externalsecret.yaml")
                   if d["kind"] == "ExternalSecret"}
        for role in ("runtime", "migrator"):
            spec = secrets[f"global-postgres-civiclens-{role}"]["spec"]
            self.assertEqual(spec["secretStoreRef"]["name"], STORE)
            self.assertEqual(spec["target"]["template"]["type"], "kubernetes.io/basic-auth")
            self.assertEqual(spec["target"]["template"]["data"]["username"], f"civiclens_{role}")
            self.assertEqual(spec["data"][0]["remoteRef"]["key"],
                             f"civiclens/prod/app/civiclens-db-{role}-password")

    def test_only_the_public_database_ca_is_published_to_civiclens(self):
        self.assertIn("civiclens-postgres-ca.yaml",
                      load("external-secrets/prod/kustomization.yaml")["resources"])
        docs = load_all("external-secrets/prod/civiclens-postgres-ca.yaml")
        [push] = [d for d in docs if d["kind"] == "PushSecret"]
        self.assertEqual(push["metadata"]["namespace"], "global")
        self.assertEqual(push["spec"]["selector"]["secret"]["name"], "global-postgres-ca")
        self.assertEqual([d["match"] for d in push["spec"]["data"]], [
            {"secretKey": "ca.crt", "remoteRef": {"remoteKey": "global-postgres-ca", "property": "ca.crt"}}
        ])
        [store] = [d for d in docs if d["kind"] == "SecretStore"]
        self.assertEqual(store["spec"]["provider"]["kubernetes"]["remoteNamespace"], "civiclens")
        [role] = [d for d in docs if d["kind"] == "Role"]
        self.assertEqual(role["metadata"]["namespace"], "civiclens")
        for rule in role["rules"]:
            self.assertEqual(rule["resources"], ["secrets"])
            self.assertNotIn("delete", rule["verbs"])
            self.assertNotIn("list", rule["verbs"])
            if set(rule["verbs"]) != {"create"}:
                self.assertEqual(rule["resourceNames"], ["global-postgres-ca"])


class CivicLensNetwork(unittest.TestCase):
    def test_gateway_host_routes_versioned_api_only(self):
        [vs] = load_all("manifests/civiclens-istio/virtualservice.yaml")
        self.assertEqual(vs["spec"]["hosts"], ["civiclns-api.tesserix.app"])
        self.assertEqual(vs["spec"]["gateways"], ["istio-ingress/tesseract-gateway"])
        large, route = vs["spec"]["http"]
        self.assertEqual(large["timeout"], "90s")
        self.assertEqual(large["match"][0], {"uri":{"exact":"/v1/reports"},"method":{"exact":"POST"}})
        self.assertEqual(large["retries"], {"attempts":0})
        self.assertEqual(route["match"], [{"uri": {"prefix": "/v1/"}}])
        self.assertEqual(route["route"][0]["destination"]["host"], "civiclens-api.civiclens.svc.cluster.local")
        self.assertEqual(route["retries"], {"attempts": 0})

    def test_gateway_admits_host_and_app_verifies_sessions(self):
        app = load("argocd/prod/infrastructure/istio-auth-policies.yaml")
        values = yaml.safe_load(app["spec"]["source"]["helm"]["values"])
        [entry] = [a for a in values["frontendApps"] if a["name"] == "civiclens-api"]
        self.assertEqual(entry, {"name": "civiclens-api", "label": "civiclens-api",
                                 "namespace": "civiclens", "hosts": ["civiclns-api.tesserix.app"]})

    def test_namespace_is_ambient_and_may_reach_global_postgres(self):
        resources = render("thirdparty/istio-config", "-f", "charts/thirdparty/istio-config/values.yaml")
        [ns] = [r for r in resources if r["kind"] == "Namespace" and r["metadata"]["name"] == "civiclens"]
        self.assertEqual(ns["metadata"]["labels"]["istio.io/dataplane-mode"], "ambient")
        policies = {(r["metadata"]["namespace"], r["metadata"]["name"]): r
                    for r in resources if r["kind"] == "NetworkPolicy"}
        self.assertIn(("civiclens", "default-deny-ingress"), policies)
        self.assertIn(("civiclens", "allow-civiclens-ingress"), policies)
        egress = str(policies[("civiclens", "allow-civiclens-egress")]["spec"])
        self.assertIn("'kubernetes.io/metadata.name': 'global'", egress)
        self.assertIn("'civiclens'", str(policies[("global", "allow-global-ingress")]["spec"]))


class CivicLensAiGateway(unittest.TestCase):
    URL = "http://civiclens-ai.agentgateway-system.svc.cluster.local:8080"

    @classmethod
    def setUpClass(cls):
        cls.resources = render("apps/civiclens-ai-gateway", "--namespace", "agentgateway-system")

    def test_only_the_api_service_account_may_invoke_the_model_route(self):
        [policy] = named(self.resources, "AuthorizationPolicy").values()
        self.assertEqual(policy["spec"]["action"], "ALLOW")
        self.assertEqual(policy["spec"]["selector"]["matchLabels"],
                         {"gateway.networking.k8s.io/gateway-name": "civiclens-ai"})
        invoke, sidecar = policy["spec"]["rules"]
        self.assertEqual(invoke["from"], [{"source": {"principals": ["cluster.local/ns/civiclens/sa/civiclens-api"]}}])
        self.assertEqual(invoke["to"], [{"operation": {"methods": ["POST"], "paths": ["/v1/chat/completions"],
                                                       "ports": ["8080"]}}])
        self.assertEqual(sidecar, {"to": [{"operation": {"notPorts": ["8080"]}}]})
        netpol = named(self.resources, "NetworkPolicy")["civiclens-ai"]
        callers = [r["from"] for r in netpol["spec"]["ingress"] if any(p["port"] == 8080 for p in r["ports"])]
        self.assertEqual(callers, [[{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "civiclens"}},
                                     "podSelector": {"matchLabels": {"app.kubernetes.io/name": "civiclens-api"}}}]])

    def test_model_route_requires_the_openbao_client_key_and_the_compose_model(self):
        [route] = named(self.resources, "HTTPRoute").values()
        self.assertEqual(route["spec"]["parentRefs"], [{"name": "civiclens-ai", "sectionName": "http"}])
        self.assertEqual(route["spec"]["rules"][0]["matches"], [{"path": {"type": "Exact", "value": "/v1/chat/completions"}, "method": "POST"}])
        traffic = named(self.resources, "AgentgatewayPolicy")["civiclens-api-model-traffic"]["spec"]["traffic"]
        self.assertEqual(traffic["apiKeyAuthentication"],
                         {"mode": "Strict", "secretRef": {"name": "civiclens-ai-gateway-clients"}})
        self.assertIn('json(request.body).model == "civiclens-compose"',
                      traffic["authorization"]["policy"]["matchExpressions"][0])
        self.assertEqual(traffic["timeouts"]["request"], "15s")
        [client] = named(self.resources, "ExternalSecret").values()
        self.assertEqual(client["spec"]["secretStoreRef"], {"name": STORE, "kind": "SecretStore"})
        self.assertEqual(client["spec"]["target"]["name"], "civiclens-ai-gateway-clients")
        self.assertEqual(client["spec"]["data"], [{"secretKey": "civiclens-api", "remoteRef": {
            "key": "civiclens/prod/app/civiclens-ai-gateway-key", "property": "value"}}])

    def test_gateway_reaches_vertex_through_workload_identity_only(self):
        [params] = named(self.resources, "AgentgatewayParameters").values()
        self.assertEqual(params["spec"]["serviceAccount"]["metadata"]["annotations"]["iam.gke.io/gcp-service-account"],
                         "agentgateway-llm@tesseracthub-480811.iam.gserviceaccount.com")
        main = (ROOT / "terraform-new/stacks/12-vertex/main.tf").read_text()
        variables = (ROOT / "terraform-new/stacks/12-vertex/variables.tf").read_text()
        self.assertIn('resource "google_service_account_iam_member" "civiclens_agentgateway_wi"', main)
        self.assertIn('"agentgateway-system/civiclens-ai"', variables)
        [backend] = named(self.resources, "AgentgatewayBackend").values()
        [provider] = backend["spec"]["ai"]["groups"][0]["providers"]
        self.assertEqual(provider["policies"]["auth"], {"gcp": {}})

    def test_api_calls_the_private_gateway_and_may_reach_only_its_pods(self):
        resources = render("apps/civiclens-api", "--namespace", "civiclens")
        container = named(resources, "Deployment")["civiclens-api"]["spec"]["template"]["spec"]["containers"][0]
        env = {e["name"]: e.get("value") for e in container["env"]}
        self.assertEqual(env["CIVICLENS_AI_GATEWAY_URL"], self.URL)
        egress = named(resources, "NetworkPolicy")["civiclens-api-ai-gateway-egress"]["spec"]
        self.assertEqual(egress["podSelector"]["matchLabels"]["app.kubernetes.io/name"], "civiclens-api")
        [rule] = egress["egress"]
        self.assertEqual(rule["to"], [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "agentgateway-system"}},
                                       "podSelector": {"matchLabels": {"gateway.networking.k8s.io/gateway-name": "civiclens-ai"}}}])
        self.assertEqual({p["port"] for p in rule["ports"]}, {8080, 15008})

    def test_gateway_application_syncs_into_agentgateway_system(self):
        app = load("argocd/prod/apps/civiclens/civiclens-ai-gateway.yaml")
        self.assertEqual(app["spec"]["project"], "civiclens")
        self.assertEqual(app["spec"]["source"]["path"], "charts/apps/civiclens-ai-gateway")
        self.assertEqual(app["spec"]["destination"]["namespace"], "agentgateway-system")
        self.assertTrue(app["spec"]["syncPolicy"]["automated"]["selfHeal"])
        destinations = {d["namespace"] for d in load("argocd/prod/projects/civiclens.yaml")["spec"]["destinations"]}
        self.assertIn("agentgateway-system", destinations)


class CivicLensDatabase(unittest.TestCase):
    def test_database_uses_existing_cnpg_with_separate_runtime_and_owner(self):
        resources = render("apps/global-postgres")
        cluster = next(r for r in resources if r["kind"] == "Cluster")
        self.assertEqual(cluster["metadata"]["name"], "global-postgres")
        roles = {r["name"]: r for r in cluster["spec"]["managed"]["roles"]}
        for name in ("civiclens_migrator", "civiclens_runtime"):
            self.assertTrue(roles[name]["login"])
            self.assertEqual(roles[name]["passwordSecret"]["name"], "global-postgres-" + name.replace("_", "-"))
            for privilege in ("superuser", "createdb", "createrole", "replication", "bypassrls"):
                self.assertFalse(roles[name].get(privilege, False))
        database = next(r for r in resources
                        if r["kind"] == "Database" and r["spec"]["name"] == "civiclens_db")
        self.assertEqual(database["spec"]["owner"], "civiclens_migrator")
        self.assertEqual(database["spec"]["cluster"]["name"], "global-postgres")
        self.assertEqual(database["spec"]["databaseReclaimPolicy"], "retain")


if __name__ == "__main__":
    unittest.main()
