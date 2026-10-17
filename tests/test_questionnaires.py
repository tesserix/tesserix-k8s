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

    def test_credential_changes_reach_database_roles_and_consumers(self):
        docs=render('charts/apps/tesserix-postgres','--set','questionnaires.enabled=true')
        for reader in (d for d in docs if d['kind']=='ExternalSecret'):
            self.assertEqual(reader['spec']['target']['template']['metadata']['labels']['cnpg.io/reload'],'true')
        for chart,role in [('company','writer'),('console','reader')]:
            docs=render(f'charts/apps/{chart}','--set','questionnaires.enabled=true')
            deployment=next(d for d in docs if d['kind']=='Deployment')
            self.assertEqual(deployment['metadata']['annotations']['secret.reloader.stakater.com/reload'],f'questionnaires-{role}')
            app=yaml.safe_load((ROOT/f'argocd/prod/apps/global/{chart}.yaml').read_text())['spec']
            self.assertIn('RespectIgnoreDifferences=true',app['syncPolicy']['syncOptions'])
            rule=next(r for r in app['ignoreDifferences'] if r['kind']=='Deployment')
            self.assertEqual(rule['name'],chart)
            self.assertEqual(rule['jqPathExpressions'],[f'.spec.template.spec.containers[].env[]? | select(.name == "STAKATER_QUESTIONNAIRES_{role.upper()}_SECRET")'])


    def test_company_uses_its_existing_mesh_identity_for_location_calls(self):
        docs=render('charts/apps/company','-f','charts/apps/company/values-prod.yaml','--set','questionnaires.enabled=true')
        deployment=next(d for d in docs if d['kind']=='Deployment')
        self.assertEqual(deployment['spec']['template']['metadata']['labels']['istio.io/dataplane-mode'],'ambient')

    def test_questionnaire_runtime_and_support_images_use_regional_gar(self):
        prefix='asia-south1-docker.pkg.dev/tesseracthub-480811/'
        for chart in ['company','console']:
            docs=render(f'charts/apps/{chart}','-f',f'charts/apps/{chart}/values-prod.yaml','--set','questionnaires.enabled=true')
            for doc in docs:
                if doc['kind'] not in ['Deployment','CronJob']: continue
                spec=doc['spec']['template']['spec'] if doc['kind']=='Deployment' else doc['spec']['jobTemplate']['spec']['template']['spec']
                for container in spec.get('initContainers',[])+spec['containers']:
                    self.assertTrue(container['image'].startswith(prefix),container['image'])
        docs=render('charts/apps/tesserix-postgres','--set','questionnaires.enabled=true')
        cluster=next(d for d in docs if d['kind']=='Cluster')
        self.assertTrue(cluster['spec']['imageName'].startswith(prefix))
        self.assertIn('@sha256:99be063781d171d3971089b49c992706bdab9ccbd2b57cdf126c7542773aedfe',cluster['spec']['imageName'])
        for doc in docs:
            if doc['kind'] not in ['Job','CronJob']: continue
            spec=doc['spec']['template']['spec'] if doc['kind']=='Job' else doc['spec']['jobTemplate']['spec']['template']['spec']
            for container in spec['containers']: self.assertTrue(container['image'].startswith(prefix),container['image'])
        app=yaml.safe_load((ROOT/'argocd/prod/apps/global/questionnaires-db-schema-bootstrap.yaml').read_text())
        self.assertTrue(app['spec']['source']['helm']['valuesObject']['image']['postgres'].startswith(prefix))
        operator=yaml.safe_load((ROOT/'charts/thirdparty/cloudnative-pg/values.yaml').read_text())['cloudnative-pg']['image']
        self.assertTrue(operator['repository'].startswith(prefix))

    def test_completed_seed_history_can_be_retained_without_database_pruning(self):
        docs=render('charts/apps/tesserix-postgres','--set','questionnaires.enabled=true')
        seed=next(d for d in docs if d['kind']=='Job')
        self.assertEqual(seed['metadata'].get('annotations',{}).get('argocd.argoproj.io/compare-options'),'IgnoreExtraneous')
        app=yaml.safe_load((ROOT/'argocd/prod/apps/global/tesserix-postgres.yaml').read_text())
        self.assertFalse(app['spec']['syncPolicy']['automated'].get('prune',False))

    def test_explicit_restart_marker_is_rendered_only_when_requested(self):
        docs=render('charts/apps/tesserix-postgres','--set-string','restartAt=2026-10-17T16:00:00Z')
        cluster=next(d for d in docs if d['kind']=='Cluster')
        self.assertEqual(cluster['metadata']['annotations']['kubectl.kubernetes.io/restartedAt'],'2026-10-17T16:00:00Z')
        docs=render('charts/apps/tesserix-postgres')
        cluster=next(d for d in docs if d['kind']=='Cluster')
        self.assertNotIn('kubectl.kubernetes.io/restartedAt',cluster['metadata'].get('annotations',{}))

    def test_backup_plugin_and_sidecars_use_pinned_regional_images(self):
        app=yaml.safe_load((ROOT/'argocd/prod/infrastructure/cnpg-barman-plugin.yaml').read_text())
        values=app['spec']['source']['helm'].get('valuesObject',{})
        for key in ['image','sidecarImage']:
            image=values.get(key,{})
            self.assertEqual(image.get('registry'),'asia-south1-docker.pkg.dev')
            self.assertTrue(image.get('repository','').startswith('tesseracthub-480811/ghcr-remote/cloudnative-pg/'))
            self.assertIn('@sha256:',image.get('tag',''))

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
