import pathlib
import subprocess
import unittest
import yaml

ROOT=pathlib.Path(__file__).resolve().parents[1]

def render(chart,*args):
    return [d for d in yaml.safe_load_all(subprocess.check_output(['helm','template','test',chart,*args],cwd=ROOT,text=True)) if d]

class QuestionnaireContracts(unittest.TestCase):
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
