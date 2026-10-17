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
