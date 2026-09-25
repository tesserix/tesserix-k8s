from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_runtime_uses_non_owner_and_migration_precedes_rollout():
    docs = list(yaml.safe_load_all(subprocess.check_output([
        'helm', 'template', 'roamie-api', str(ROOT / 'charts/apps/roamie-api'),
        '--set', 'database.enabled=true', '--set', 'image.tag=main-tested'], text=True)))
    deployment = next(d for d in docs if d and d['kind'] == 'Deployment')
    pod = deployment['spec']['template']['spec']
    app = pod['containers'][0]
    env = {e['name']: e for e in app['env']}
    assert env['PGHOST']['value'] == 'roamie-postgres-rw.roamie.svc.cluster.local'
    assert env['PGUSER']['valueFrom']['secretKeyRef']['name'] == 'roamie-postgres-runtime'
    assert env['PGPASSWORD']['valueFrom']['secretKeyRef']['name'] == 'roamie-postgres-runtime'
    assert env['PGSSLROOTCERT']['value'] == '/etc/postgres/ca.crt'
    assert app['readinessProbe']['httpGet']['path'] == '/readyz'
    assert app['livenessProbe']['httpGet']['path'] == '/healthz'
    assert pod['volumes'][0]['secret']['secretName'] == 'roamie-postgres-ca'
    job = next(d for d in docs if d and d['kind'] == 'Job')
    assert job['metadata']['annotations']['argocd.argoproj.io/hook'] == 'Sync'
    assert int(job['metadata']['annotations']['argocd.argoproj.io/sync-wave']) < 0
    migration = job['spec']['template']['spec']['containers'][0]
    assert migration['image'] == app['image']
    assert migration['args'] == ['migrate']
    credentials = {e['name']: e for e in migration['env']}
    assert credentials['PGPASSWORD']['valueFrom']['secretKeyRef']['name'] == 'roamie-postgres-app'
    assert credentials['PGUSER']['valueFrom']['secretKeyRef']['name'] == 'roamie-postgres-app'
    assert job['spec']['activeDeadlineSeconds'] <= 300
