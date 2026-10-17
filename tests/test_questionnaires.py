import pathlib
import subprocess
import unittest
import yaml

ROOT=pathlib.Path(__file__).resolve().parents[1]

def render(chart,*args):
    return [d for d in yaml.safe_load_all(subprocess.check_output(['helm','template','test',chart,*args],cwd=ROOT,text=True)) if d]

class QuestionnaireContracts(unittest.TestCase):
    def test_gateway_admits_only_public_research_paths_without_a_principal(self):
        docs=render('charts/thirdparty/istio-config','-f','charts/thirdparty/istio-config/values-prod.yaml')
        policy=next(d for d in docs if d['kind']=='AuthorizationPolicy' and d['metadata']['name']=='allow-questionnaires-public')
        self.assertEqual(policy['metadata']['namespace'],'istio-ingress')
        self.assertEqual(policy['spec']['selector']['matchLabels'],{'istio':'ingressgateway'})
        for rule in policy['spec']['rules']:
            self.assertNotIn('from',rule)
            self.assertNotIn('when',rule)
            op=rule['to'][0]['operation']
            self.assertEqual(op['hosts'],['questionnaire.tesserix.app','questionnaire.tesserix.app:*'])
            self.assertNotIn('/api/*',op['paths'])
            self.assertNotIn('/admin/*',op['paths'])
        self.assertEqual(policy['spec']['rules'][1]['to'][0]['operation']['methods'],['POST'])

    def test_public_lookup_is_admitted_without_exposing_other_api_routes(self):
        docs=render('charts/apps/company','--set','questionnaires.enabled=true')
        vs=next(d for d in docs if d['kind']=='VirtualService' and d['metadata']['name']=='questionnaires')
        matches=[m for route in vs['spec']['http'] for m in route.get('match',[])]
        self.assertIn({'uri':{'exact':'/api/questionnaires/location'}},matches)
        docs=render('charts/thirdparty/istio-config','-f','charts/thirdparty/istio-config/values-prod.yaml')
        policy=next(d for d in docs if d['kind']=='AuthorizationPolicy' and d['metadata']['name']=='allow-questionnaires-public')
        self.assertIn('/api/questionnaires/location',policy['spec']['rules'][1]['to'][0]['operation']['paths'])

    def test_database_is_retained_on_the_existing_cluster_and_roles_have_no_admin_grant(self):
        docs=render('charts/apps/tesserix-postgres','--set','questionnaires.enabled=true')
        db=next(d for d in docs if d['kind']=='Database')
        self.assertEqual(db['spec'],{'cluster':{'name':'tesserix-postgres'},'name':'questionnaires','owner':'tesserix_admin','ensure':'present','databaseReclaimPolicy':'retain'})
        cluster=next(d for d in docs if d['kind']=='Cluster')
        roles=cluster['spec']['managed']['roles']
        self.assertEqual({r['name'] for r in roles},{'questionnaires_writer','questionnaires_reader'})
        for role in roles:
            for privilege in ['superuser','createdb','createrole','bypassrls','replication']:
                self.assertFalse(role.get(privilege,False))
        for doc in docs:
            if doc['kind']=='ExternalSecret':
                self.assertEqual(doc['spec']['secretStoreRef']['kind'],'SecretStore')
                self.assertTrue(doc['spec']['data'][0]['remoteRef']['key'].startswith('questionnaires/prod/app/'))

    def test_credential_readers_recover_promptly_after_seed(self):
        docs=render('charts/apps/tesserix-postgres','--set','questionnaires.enabled=true')
        readers=[d for d in docs if d['kind']=='ExternalSecret']
        self.assertEqual(len(readers),2)
        for reader in readers:
            self.assertEqual(reader['spec']['refreshInterval'],'1m')

    def test_disabled_feature_adds_no_database_or_secret_seed(self):
        docs=render('charts/apps/tesserix-postgres')
        self.assertFalse(any(d['kind'] in ['Database','Job','ExternalSecret'] for d in docs))

    def test_secret_seed_preserves_existing_values_and_has_exact_namespace_bound_access(self):
        v=yaml.safe_load((ROOT/'charts/thirdparty/openbao/values.yaml').read_text())['bootstrap']
        policies={p['name']:p['hcl'] for p in v['policies']}
        roles={r['name']:r for r in v['kubernetesRoles']}
        for name in ['questionnaires-writer-reader','questionnaires-reader-reader','questionnaires-secret-seed']:
            self.assertEqual(roles[name]['namespaces'],['tesserix'])
            self.assertEqual(roles[name]['serviceAccounts'],[name])
            self.assertNotIn('*',policies[name])
            self.assertNotIn('"delete"',policies[name])
        self.assertNotIn('"update"',policies['questionnaires-writer-reader'])
        self.assertNotIn('questionnaires-reader-password',policies['questionnaires-writer-reader'])
        self.assertNotIn('questionnaires-writer-password',policies['questionnaires-reader-reader'])

    def test_schema_bootstrap_targets_only_questionnaires(self):
        app=yaml.safe_load((ROOT/'argocd/prod/apps/global/questionnaires-db-schema-bootstrap.yaml').read_text())
        values=app['spec']['source']['helm']['valuesObject']
        self.assertEqual(len(values['targets']),1)
        target=values['targets'][0]
        self.assertEqual(target['host'],'tesserix-postgres-rw.tesserix.svc.cluster.local')
        self.assertEqual(target['combineInto'],'questionnaires')
        self.assertEqual(target['reapplyExistingSchemas'],['questionnaires'])
        self.assertNotIn('applySchemaToExistingDatabases',values)
        self.assertIn('questionnaires-db-schema-bootstrap.yaml',yaml.safe_load((ROOT/'argocd/prod/apps/global/kustomization.yaml').read_text())['resources'])

if __name__=='__main__': unittest.main()
