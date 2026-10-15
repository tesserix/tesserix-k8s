import pathlib
import subprocess
import unittest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
HAPROXY = {
    'app.kubernetes.io/name': 'global-valkey-cache',
    'app.kubernetes.io/instance': 'global-valkey-cache',
    'app.kubernetes.io/component': 'haproxy',
}


def render(chart, *args, release=None):
    output = subprocess.check_output(
        ['helm', 'template', release or chart, str(ROOT / 'charts/apps' / chart), *args], text=True
    )
    return [item for item in yaml.safe_load_all(output) if item]


def named(resources, kind, name):
    return next(i for i in resources if i['kind'] == kind and i['metadata']['name'] == name)


def cache():
    return render(
        'global-valkey',
        '-f',
        str(ROOT / 'charts/apps/global-valkey/values-cache.yaml'),
        release='global-valkey-cache',
    )


def api_env(*settings):
    args = [a for s in settings for a in ('--set', s)]
    deployment = named(render('helivanta-api', *args), 'Deployment', 'helivanta-api')
    return {i['name']: i.get('value') for i in deployment['spec']['template']['spec']['containers'][0]['env']}


class HelivantaValkey(unittest.TestCase):
    def test_acl_scopes_helivanta_to_its_prefix(self):
        config = named(cache(), 'ConfigMap', 'global-valkey-cache-config')
        self.assertIn(
            'user helivanta on nopass ~helivanta:* &helivanta:* +@all -@dangerous',
            config['data']['users.acl'],
        )

    def test_helivanta_is_admitted_per_workload_never_per_namespace(self):
        resources = cache()
        shared = named(resources, 'NetworkPolicy', 'global-valkey-cache')
        self.assertNotIn('helivanta', str(shared))
        policy = named(resources, 'NetworkPolicy', 'global-valkey-cache-mesh-clients')['spec']
        self.assertEqual(HAPROXY, policy['podSelector']['matchLabels'])
        self.assertEqual(
            [
                {
                    'from': [
                        {
                            'namespaceSelector': {'matchLabels': {'kubernetes.io/metadata.name': 'helivanta'}},
                            'podSelector': {'matchLabels': {'app.kubernetes.io/name': 'helivanta-api'}},
                        }
                    ],
                    'ports': [{'protocol': 'TCP', 'port': 15008}],
                }
            ],
            policy['ingress'],
        )

    def test_tunnelled_clients_are_denied_every_port_but_valkey(self):
        policy = named(cache(), 'AuthorizationPolicy', 'global-valkey-cache-mesh-clients')['spec']
        self.assertEqual('DENY', policy['action'])
        self.assertEqual(HAPROXY, policy['selector']['matchLabels'])
        self.assertEqual(
            [
                {
                    'from': [{'source': {'principals': ['cluster.local/ns/helivanta/sa/helivanta-api']}}],
                    'to': [{'operation': {'notPorts': ['6379']}}],
                }
            ],
            policy['rules'],
        )

    def test_api_uses_shared_valkey_only_with_a_mesh_identity(self):
        env = api_env('documents.enabled=true', 'documents.acceptUploads=true')
        self.assertEqual(
            'redis://helivanta:nopass@global-valkey-cache.global.svc.cluster.local:6379', env.get('VALKEY_URL')
        )
        self.assertEqual('100ms', env.get('VALKEY_TIMEOUT'))
        self.assertNotIn('VALKEY_URL', api_env('documents.enabled=true'))
        self.assertNotIn('VALKEY_URL', api_env())

    def test_api_egress_reaches_only_haproxy_over_hbone(self):
        policy = named(render('helivanta-network-policies'), 'NetworkPolicy', 'allow-helivanta-api-valkey')['spec']
        self.assertEqual({'app.kubernetes.io/name': 'helivanta-api'}, policy['podSelector']['matchLabels'])
        self.assertEqual(
            [
                {
                    'to': [
                        {
                            'namespaceSelector': {'matchLabels': {'kubernetes.io/metadata.name': 'global'}},
                            'podSelector': {
                                'matchLabels': {
                                    'app.kubernetes.io/instance': 'global-valkey-cache',
                                    'app.kubernetes.io/component': 'haproxy',
                                }
                            },
                        }
                    ],
                    'ports': [{'protocol': 'TCP', 'port': 15008}],
                }
            ],
            policy['egress'],
        )


if __name__ == '__main__':
    unittest.main()
