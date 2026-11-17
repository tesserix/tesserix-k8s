import json
from pathlib import Path
import subprocess
import unittest
import yaml

ROOT = Path(__file__).parents[1]

class CatalogueChartTests(unittest.TestCase):
    def render(self, chart, *args):
        result = subprocess.run(['helm', 'template', 'test', str(ROOT / chart), *args], check=True, capture_output=True, text=True)
        return list(yaml.safe_load_all(result.stdout))

    def test_onboarding_publishes_catalogue_and_same_runtime_schema(self):
        objects = self.render('charts/apps/onboarding-service', '-f', str(ROOT / 'charts/apps/onboarding-service/values-prod.yaml'))
        config = next(row for row in objects if row and row['kind'] == 'ConfigMap' and row['metadata']['name'] == 'helivanta-feature-catalogue')
        self.assertEqual(config['metadata']['namespace'], 'helivanta-growthbook')
        schema = json.loads(config['data']['schema.json'])
        self.assertEqual(schema, json.loads((ROOT / 'charts/apps/onboarding-service/files/helivanta-catalogue.schema.json').read_text()))
        catalogue = json.loads(config['data']['catalogue.json'])
        self.assertGreater(len(catalogue['capabilities']), 0)
        for bad in ({**catalogue, 'unknown': True}, {**catalogue, 'capabilities': []}):
            result = subprocess.run(['helm', 'template', 'test', str(ROOT / 'charts/apps/onboarding-service'), '-f', str(ROOT / 'charts/apps/onboarding-service/values-prod.yaml'), '--set-json', 'helivantaFeatureCatalogue.catalogue=' + json.dumps(bad)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_reconciler_has_no_api_token_and_uses_provider_pin(self):
        objects = self.render('charts/thirdparty/growthbook', '--set', 'helivantaDedicated.enabled=true', '--set', 'helivantaRelease.enabled=true', '--set', 'helivantaRelease.consoleManaged=true', '--set', 'helivantaCatalogue.enabled=true', '--set', 'apiOnly=true')
        job = next(row for row in objects if row and row['kind'] == 'CronJob')
        self.assertEqual(job['spec']['concurrencyPolicy'], 'Forbid')
        spec = job['spec']['jobTemplate']['spec']['template']['spec']
        self.assertFalse(spec['automountServiceAccountToken'])
        self.assertNotIn('serviceAccountToken', json.dumps(spec['volumes']))
        self.assertIn('@sha256:', spec['containers'][0]['image'])
        self.assertEqual(spec['containers'][0]['command'], ['node', '/config/helivanta-catalogue.mjs', '--run'])
        self.assertTrue(all(row['readOnly'] for row in spec['containers'][0]['volumeMounts']))

if __name__ == '__main__':
    unittest.main()
