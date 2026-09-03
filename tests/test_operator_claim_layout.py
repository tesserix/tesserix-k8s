import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]


class OperatorClaimLayoutTests(unittest.TestCase):
    def test_analytics_operator_resources_are_gke_compatible(self):
        resources_path = ROOT / "k8s/operators/analytics-onboarding/resources.yaml"
        resources = list(yaml.safe_load_all(resources_path.read_text()))

        crd = next(resource for resource in resources if resource["kind"] == "CustomResourceDefinition")
        spec_schema = crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]
        self.assertNotIn("uniqueItems", spec_schema["properties"]["cors"])
        self.assertNotIn("uniqueItems", spec_schema["properties"]["types"])

        policy = next(resource for resource in resources if resource["kind"] == "NetworkPolicy")
        metadata_endpoints = {
            (target["ipBlock"]["cidr"], port["port"])
            for rule in policy["spec"]["egress"]
            for target in rule.get("to", [])
            if "ipBlock" in target
            and target["ipBlock"]["cidr"].startswith("169.254.")
            for port in rule.get("ports", [])
        }
        self.assertEqual(
            metadata_endpoints,
            {("169.254.169.254/32", 80), ("169.254.169.252/32", 988)},
        )

    def test_claims_live_with_their_operators_and_are_deployed(self):
        operators = {
            "zitadel": {
                "application": ROOT / "argocd/prod/infrastructure/zitadel-operator.yaml",
                "claims": ["homechef.yaml", "langfuse.yaml"],
            },
            "db-anonymise": {
                "application": ROOT / "argocd/prod/apps/ai-apps/devai-sandbox-operator.yaml",
                "claims": ["kora.yaml"],
            },
            "analytics-onboarding": {
                "application": ROOT / "argocd/prod/infrastructure/analytics-onboarding-operator.yaml",
                "claims": ["langfuse.yaml", "devai.yaml"],
            },
            "evals-onboarding": {
                "application": ROOT / "argocd/prod/infrastructure/evals-onboarding-operator.yaml",
                "claims": ["devai.yaml", "kora.yaml", "australis.yaml", "ocr.yaml"],
            },
        }

        for operator, expected_claims in operators.items():
            operator_dir = ROOT / "k8s/operators" / operator
            claims_dir = operator_dir / "claims"
            self.assertTrue((operator_dir / "kustomization.yaml").is_file())
            self.assertTrue((claims_dir / "kustomization.yaml").is_file())
            claims_kustomization = (claims_dir / "kustomization.yaml").read_text()
            for claim in expected_claims["claims"]:
                self.assertIn(f"- {claim}", claims_kustomization)
            self.assertIn(f"path: k8s/operators/{operator}", expected_claims["application"].read_text())
            self.assertIn("- claims", (operator_dir / "kustomization.yaml").read_text())

        self.assertFalse((ROOT / "k8s/claims/identity/zitadel").exists())
        self.assertFalse((ROOT / "operators/claims/db-anonymise").exists())
        self.assertFalse((ROOT / "operators/db-anonymise").exists())
        self.assertFalse((ROOT / "argocd/prod/infrastructure/zitadel-claims.yaml").exists())

    def test_langfuse_claim_restricts_tokens_to_platform_operators(self):
        claim_path = ROOT / "k8s/operators/zitadel/claims/langfuse.yaml"
        claim = yaml.safe_load(claim_path.read_text())

        self.assertEqual(claim["kind"], "ZitadelProject")
        self.assertEqual(claim["metadata"]["namespace"], "identity-operator")
        self.assertEqual(claim["spec"]["organization"], "TESSERIX")
        self.assertEqual(claim["spec"]["access"], {
            "mode": "restricted",
            "members": [
                {"email": "samyak.rout@gmail.com", "roles": ["admin"]},
                {"email": "mahesh.sangawar@gmail.com", "roles": ["admin"]},
            ],
        })


if __name__ == "__main__":
    unittest.main()
