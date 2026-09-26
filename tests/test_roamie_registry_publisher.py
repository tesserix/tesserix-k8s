import unittest

from test_agentregistry_zitadel_auth import render_registry, resource


class RoamieRegistryPublisherTests(unittest.TestCase):
    def test_publisher_key_is_hashed_and_scoped_to_roamie(self):
        documents = render_registry()
        deployment = resource(documents, 'Deployment', 'agentregistry')
        env = {item['name']: item for item in deployment['spec']['template']['spec']['containers'][0]['env']}
        self.assertIn('roamie=$(ROAMIE_DEPLOY_KEY_SHA256)', env['AUTH_DEPLOY_KEYS']['value'])
        self.assertEqual(env['ROAMIE_DEPLOY_KEY_SHA256']['valueFrom']['secretKeyRef']['key'], 'ROAMIE_DEPLOY_KEY_SHA256')
        secret = resource(documents, 'ExternalSecret', 'agentregistry-secrets')
        keys = {item['secretKey']: item['remoteRef']['key'] for item in secret['spec']['data']}
        self.assertEqual(keys['ROAMIE_DEPLOY_KEY_SHA256'], 'prod-agentic-registry-roamie-deploy-key-sha256')
        self.assertNotIn('ROAMIE_DEPLOY_KEY', keys)
