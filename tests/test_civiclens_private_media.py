import pathlib
import subprocess
import unittest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CivicLensPrivateMedia(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.resources = list(yaml.safe_load_all(subprocess.check_output([
            'helm', 'template', 'civiclens-api', 'charts/apps/civiclens-api',
            '--namespace', 'civiclens'], cwd=ROOT, text=True)))

    def test_private_uploads_use_workload_identity_and_no_static_key(self):
        deployment = next(r for r in self.resources if r and r['kind'] == 'Deployment')
        spec = deployment['spec']['template']['spec']
        env = {e['name']: e.get('value') for e in spec['containers'][0]['env']}
        self.assertEqual(env['CIVICLENS_MEDIA_BUCKET'], 'civiclens-prod-report-media-in')
        self.assertNotIn('GOOGLE_APPLICATION_CREDENTIALS', env)
        self.assertGreaterEqual(spec['terminationGracePeriodSeconds'], 90)
        self.assertFalse(spec['automountServiceAccountToken'])
        policies = [r for r in self.resources if r and r['kind'] == 'NetworkPolicy']
        media = next(r for r in policies if r['metadata']['name'] == 'civiclens-api-media-egress')
        self.assertIn('169.254.169.254/32', str(media))
        self.assertNotIn('port: 8200', str(media))

    def test_bucket_prevents_public_access_and_the_api_cannot_list_or_delete_objects(self):
        text = (ROOT / 'terraform-new/stacks/03-storage/civiclens-media.tf').read_text()
        self.assertIn('public_access_prevention    = "enforced"', text)
        self.assertIn('uniform_bucket_level_access = true', text)
        self.assertIn('force_destroy               = false', text)
        self.assertIn('prevent_destroy = true', text)
        self.assertIn('"storage.objects.create", "storage.objects.get"', text)
        self.assertNotIn('storage.objects.delete', text)
        self.assertNotIn('storage.objects.list', text)
        self.assertIn('/subject/ns/civiclens/sa/civiclens-api', text)

    def test_large_report_routes_have_a_bounded_deadline_without_retries(self):
        vs = yaml.safe_load((ROOT / 'manifests/civiclens-istio/virtualservice.yaml').read_text())
        routes = vs['spec']['http']
        self.assertTrue(any(r['timeout'] == '90s' for r in routes))
        self.assertTrue(any(r['timeout'] == '30s' for r in routes))
        for route in routes:
            self.assertEqual(route['retries']['attempts'], 0)


if __name__ == '__main__':
    unittest.main()
