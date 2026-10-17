import pathlib
import subprocess
import unittest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]

class HospitalIdentity(unittest.TestCase):
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
