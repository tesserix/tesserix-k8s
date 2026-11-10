from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class OperatorRevisionTests(unittest.TestCase):
    def test_parent_preserves_only_the_operator_promoted_revision(self):
        parent = yaml.safe_load((ROOT / 'argocd/prod/infrastructure-app.yaml').read_text())
        rules = [rule for rule in parent['spec']['ignoreDifferences']
                 if '/spec/source/targetRevision' in rule.get('jsonPointers', [])]
        self.assertEqual(rules, [{'group': 'argoproj.io', 'kind': 'Application',
                                 'name': 'zitadel-operator', 'namespace': 'argocd',
                                 'jsonPointers': ['/spec/source/targetRevision']}])
        self.assertIn('RespectIgnoreDifferences=true', parent['spec']['syncPolicy']['syncOptions'])
