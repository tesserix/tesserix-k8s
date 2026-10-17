import pathlib
import subprocess
import unittest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]

class HospitalIdentity(unittest.TestCase):
    def test_product_oauth_reaches_only_the_reviewed_onboarding_host(self):
        app = yaml.safe_load((ROOT / "argocd/prod/infrastructure/istio-auth-policies.yaml").read_text())
        values = yaml.safe_load((ROOT / "charts/infrastructure/istio-auth-policies/values.yaml").read_text())
        values.update(yaml.safe_load(app["spec"]["source"]["helm"]["values"]))
        zitadel = next(e for e in values["extraGip"] if e["issuer"] == "https://auth.tesserix.app")
        self.assertIn("395476377970673709", zitadel["audiences"])
        self.assertIn("onboard.tesserix.app", zitadel["restrictToHosts"])
        rendered = list(yaml.safe_load_all(subprocess.check_output(["helm", "template", "istio-auth-policies", str(ROOT / "charts/infrastructure/istio-auth-policies"), "-f", "-"], input=yaml.safe_dump(values), text=True)))
        rules = [r for d in rendered if d and d["kind"] == "RequestAuthentication" for r in d["spec"].get("jwtRules", []) if r["issuer"] == "https://auth.tesserix.app"]
        self.assertEqual(len(rules), len(values["ingressGateways"]))
        for rule in rules:
            self.assertIn("395476377970673709", rule["audiences"])
            self.assertTrue(rule["forwardOriginalToken"])

    def test_operator_installs_private_claim_and_audience_bound_identity(self):
        docs = list(yaml.safe_load_all(subprocess.check_output(["kubectl", "kustomize", str(ROOT / "k8s/operators/zitadel")], text=True)))
        crds = {d["metadata"]["name"]: d for d in docs if d and d["kind"] == "CustomResourceDefinition"}
        self.assertIn("zitadelorganizations.identity.tesserix.app", crds)
        deploy = next(d for d in docs if d and d["kind"] == "Deployment")
        spec = deploy["spec"]["template"]["spec"]
        token = next(v for v in spec["volumes"] if v["name"] == "onboarding-identity")
        self.assertEqual(token["projected"]["sources"][0]["serviceAccountToken"]["audience"], "onboarding-provisioning")
        self.assertFalse(any(d and d["kind"] == "ZitadelOrganization" for d in docs), "Customer records must stay out of public GitOps")

    def test_provisioning_reaches_workload_auth_without_browser_session(self):
        docs = list(yaml.safe_load_all(subprocess.check_output(["helm", "template", "helivanta-istio", str(ROOT / "charts/apps/helivanta-istio"), "--namespace", "helivanta"], text=True)))
        service = next(d for d in docs if d and d["kind"] == "VirtualService")
        route = next((r for r in service["spec"]["http"] if r.get("match") == [{"uri": {"exact": "/api/internal/v1/hospital-enrolments"}}]), None)
        self.assertIsNotNone(route, "Workload provisioning must bypass the shell's browser-cookie middleware")
        self.assertEqual(route["rewrite"]["uri"], "/internal/v1/hospital-enrolments")
        self.assertEqual(route["route"][0]["destination"]["host"], "helivanta-api.helivanta.svc.cluster.local")
        self.assertFalse(any(m.get("uri", {}).get("prefix", "").startswith("/api/internal") for r in service["spec"]["http"] for m in r.get("match", [])))

    def test_product_reader_is_namespace_bound_and_cannot_rotate_credentials(self):
        values = yaml.safe_load((ROOT / "charts/thirdparty/openbao/values.yaml").read_text())
        bootstrap = values["bootstrap"]
        name = "helivanta-onboarding-client-reader"
        role = next((r for r in bootstrap["kubernetesRoles"] if r["name"] == name), None)
        self.assertIsNotNone(role, "The product needs its own namespace-bound reader, separate from the operator writer")
        self.assertEqual(role["serviceAccounts"], ["helivanta-api"])
        self.assertEqual(role["namespaces"], ["helivanta"])
        self.assertEqual(role["policies"], [name])
        policy = next(p["hcl"] for p in bootstrap["policies"] if p["name"] == name)
        self.assertIn('path "kv/data/helivanta/prod/app/helivanta-onboarding-client" { capabilities = ["read"] }', policy)
        self.assertNotIn('"update"', policy)
        self.assertNotIn('"delete"', policy)
        self.assertNotIn('*', policy)
