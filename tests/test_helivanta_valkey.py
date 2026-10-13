import pathlib
import subprocess
import unittest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]

def render(chart, *args):
    output = subprocess.check_output(['helm', 'template', chart, str(ROOT/'charts/apps'/chart), *args], text=True)
    return list(yaml.safe_load_all(output))

class HelivantaValkey(unittest.TestCase):
    def test_shared_cache_scope_and_namespace_are_declared(self):
        resources = render('global-valkey', '-f', str(ROOT/'charts/apps/global-valkey/values-cache.yaml'))
        config = next(item for item in resources if item['kind']=='ConfigMap')
        self.assertIn('user helivanta on nopass ~helivanta:* &helivanta:* +@all -@dangerous', config['data']['users.acl'])
        policy = next(item for item in resources if item['kind']=='NetworkPolicy')
        self.assertIn('helivanta', str(policy))

    def test_api_uses_shared_valkey_and_only_scoped_egress(self):
        deployment = next(item for item in render('helivanta-api') if item['kind']=='Deployment')
        env = {item['name']: item.get('value') for item in deployment['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual('redis://helivanta:nopass@global-valkey-cache.global.svc.cluster.local:6379', env.get('VALKEY_URL'))
        self.assertEqual('100ms', env.get('VALKEY_TIMEOUT'))
        policy = next(item for item in render('helivanta-network-policies') if item['metadata']['name']=='allow-helivanta-api-valkey')
        self.assertEqual({'app.kubernetes.io/name':'helivanta-api'}, policy['spec']['podSelector']['matchLabels'])
        self.assertEqual([{'protocol':'TCP','port':6379}],policy['spec']['egress'][0]['ports'])
        self.assertEqual({'kubernetes.io/metadata.name':'global'},policy['spec']['egress'][0]['to'][0]['namespaceSelector']['matchLabels'])

if __name__=='__main__': unittest.main()
