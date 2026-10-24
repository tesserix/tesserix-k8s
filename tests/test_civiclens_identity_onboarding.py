import json
import pathlib
import subprocess
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CivicLensIdentityOnboarding(unittest.TestCase):
    def test_operator_claim_uses_isolated_org_and_all_three_social_providers(self):
        claims = list(yaml.safe_load_all((ROOT / 'k8s/operators/zitadel/claims/civiclens.yaml').read_text()))
        project = claims[0]['spec']
        self.assertEqual(project['organization'], 'CivicLens')
        self.assertEqual(project['access']['mode'], 'public')
        self.assertEqual({p['kind'] for p in project['consumerOrganization']['providers']}, {'google', 'apple', 'facebook'})
        for claim in claims[1:]:
            self.assertEqual(claim['spec']['redirectUris'], ['civiclens:/auth/callback'])
            self.assertEqual(claim['spec']['applicationType'], 'native')
            self.assertTrue(claim['spec']['idTokenUserinfoAssertion'])

    def test_rollout_uses_scanned_immutable_releases_and_preserves_login(self):
        operator = yaml.safe_load(
            (ROOT / 'k8s/operators/zitadel/kustomization.yaml').read_text()
        )
        self.assertEqual(operator['images'][0]['digest'],
                         'sha256:44c41e4f7355e5e45e3240031586d0624b7f31090fbd081bb71fb284a4c0e626')
        values = yaml.safe_load((ROOT / 'charts/thirdparty/zitadel/values.yaml').read_text())['zitadel']
        self.assertEqual(values['image']['repository'],
                         'asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/zitadel-api-patched')
        self.assertEqual(values['image']['tag'],
                         'sha-29986e1b8b3e606d20871a2e73874b91f9b5b695@sha256:22ab1fb4abe6a5f279c5509fa2bbb10358a2fc9fb479af013235add8af1188ac')
        self.assertEqual(values['login']['image']['tag'], 'feat-consumer-email-otp-e688e06@sha256:856166971b3f157e61860778ab4ba1d76f52a21cde8466e1984aa8dbfb59d103')

    def test_openbao_reader_is_bound_to_operator_with_exact_read_only_paths(self):
        rendered = subprocess.check_output(['helm', 'template', 'openbao', 'charts/thirdparty/openbao', '--show-only', 'templates/bootstrap-configmap.yaml'], cwd=ROOT, text=True)
        document = yaml.safe_load(rendered)
        data = document['data']
        role = json.loads(data['role-zitadel-consumer-provider-reader.json'])
        self.assertEqual(role['bound_service_account_names'], ['zitadel-operator'])
        self.assertEqual(role['bound_service_account_namespaces'], ['identity-operator'])
        self.assertEqual(role['audience'], 'openbao')
        writer = json.loads(data['role-zitadel-machine-user-writer.json'])
        self.assertNotIn('audience', writer)
        resources = list(yaml.safe_load_all((ROOT / 'k8s/operators/zitadel/resources.yaml').read_text()))
        deployment = next(r for r in resources if r and r['kind'] == 'Deployment' and r['metadata']['name'] == 'zitadel-operator')
        pod = deployment['spec']['template']['spec']
        env = {v['name']: v['value'] for v in pod['containers'][0]['env']}
        self.assertEqual(env['CONSUMER_PROVIDER_WORKLOAD_JWT_FILE'], '/var/run/openbao/token')
        self.assertNotIn('OPENBAO_WORKLOAD_JWT_FILE', env)
        token = next(v for v in pod['volumes'] if v['name'] == 'openbao-token')['projected']['sources'][0]['serviceAccountToken']
        self.assertEqual(token['audience'], role['audience'])
        self.assertLessEqual(token['expirationSeconds'], 600)
        policy = data['policy-zitadel-consumer-provider-reader.hcl']
        self.assertNotIn('*', policy)
        self.assertNotIn('update', policy)
        self.assertNotIn('create', policy)
        self.assertNotIn('delete', policy)
        for provider in ['google', 'apple', 'facebook']:
            self.assertIn(f'kv/data/civiclens/prod/app/civiclens-{provider}-idp-prod', policy)
        self.assertNotIn('/dev/', policy)
        self.assertNotIn('/uat/', policy)


if __name__ == '__main__':
    unittest.main()
