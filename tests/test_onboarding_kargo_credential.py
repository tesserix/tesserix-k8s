import pathlib
import subprocess
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


class OnboardingKargoCredential(unittest.TestCase):
    def test_rendered_credential_is_scoped_to_onboarding_repository(self):
        rendered = subprocess.check_output(
            ['kubectl', 'kustomize', str(ROOT / 'external-secrets/prod')], text=True
        )
        matches = [doc for doc in yaml.safe_load_all(rendered)
                   if doc and doc.get('kind') == 'ExternalSecret'
                   and doc['metadata'].get('namespace') == 'kargo-onboarding']
        self.assertEqual(len(matches), 1)
        spec = matches[0]['spec']
        self.assertEqual(spec['target']['template']['metadata']['labels'],
                         {'kargo.akuity.io/cred-type': 'git'})
        self.assertEqual(spec['target']['template']['data']['repoURL'],
                         'https://github.com/tesserix/onboarding-service.git')
        self.assertEqual(spec['secretStoreRef']['name'], 'gcp-secret-store')
        self.assertEqual({entry['remoteRef']['key'] for entry in spec['data']},
                         {'prod-ghcr-username', 'prod-ghcr-token'})


if __name__ == '__main__':
    unittest.main()
