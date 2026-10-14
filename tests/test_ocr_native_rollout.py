from test_kora_ai_gateway_manifests import render_chart, resource


def test_native_migrations_are_opt_in_and_run_before_the_worker_rollout():
    defaults = render_chart('charts/apps/document-intelligence', 'ocr', 'document-intelligence', 'values-sandbox.yaml', ('schemaMigration.enabled=false',))
    assert not any(doc['kind'] == 'Job' for doc in defaults)
    docs = render_chart('charts/apps/document-intelligence', 'ocr', 'document-intelligence', 'values-sandbox.yaml', ('schemaMigration.enabled=true',))
    job = resource(docs, 'Job', 'document-intelligence-sandbox-native-migrations')
    assert job['metadata']['namespace'] == 'global'
    assert job['metadata']['annotations']['argocd.argoproj.io/hook'] == 'PreSync'
    pod = job['spec']['template']['spec']
    assert pod['automountServiceAccountToken'] is False
    container = pod['containers'][0]
    assert '@sha256:' in container['image']
    env = {item['name']: item for item in container['env']}
    assert env['PGDATABASE']['value'] == 'document_intelligence_sandbox_db'
    assert env['PGPASSWORD']['valueFrom']['secretKeyRef'] == {'name': 'global-postgres-app-credentials', 'key': 'password'}
    assert env['PGUSER']['valueFrom']['secretKeyRef'] == {'name': 'global-postgres-app-credentials', 'key': 'username'}
    assert container['securityContext']['readOnlyRootFilesystem'] is True
    cm = resource(docs, 'ConfigMap', 'document-intelligence-sandbox-native-migrations')
    assert 'pg_advisory_lock' in cm['data']['run.psql']
    for version in ('0019', '0020', '0021'):
        script = next(value for key, value in cm['data'].items() if key.startswith(version))
        assert script.index('insert into ocr_native_schema_migrations') < script.rindex('commit;')
    assert 'DATABASE_URL' not in cm['data']['run.psql']


def test_execution_memory_is_separate_from_dispatch_memory():
    docs = render_chart('charts/apps/document-intelligence', 'ocr', 'document-intelligence', 'values-prod.yaml')
    execution = resource(docs, 'Deployment', 'document-intelligence-prod-execution-worker')
    dispatch = resource(docs, 'Deployment', 'document-intelligence-prod-dispatch-worker')
    assert execution['spec']['template']['spec']['containers'][0]['resources']['limits']['memory'] == '4Gi'
    assert dispatch['spec']['template']['spec']['containers'][0]['resources']['limits']['memory'] == '1Gi'
