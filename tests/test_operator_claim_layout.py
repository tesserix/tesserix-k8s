import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class OperatorClaimLayoutTests(unittest.TestCase):
    def test_claims_live_with_their_operators_and_are_deployed(self):
        operators = {
            "zitadel": {
                "application": ROOT / "argocd/prod/infrastructure/zitadel-operator.yaml",
                "claims": ["homechef.yaml"],
            },
            "db-anonymise": {
                "application": ROOT / "argocd/prod/apps/ai-apps/devai-sandbox-operator.yaml",
                "claims": ["kora.yaml"],
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


if __name__ == "__main__":
    unittest.main()
