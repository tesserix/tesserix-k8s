from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_runtime_pooling_and_bootstrap_use_same_homechef_database():
    api = yaml.safe_load((ROOT / 'charts/apps/homechef-api/values-prod.yaml').read_text())
    company = yaml.safe_load((ROOT / 'charts/apps/company/values.yaml').read_text())
    app = yaml.safe_load((ROOT / 'argocd/prod/apps/homechef/homechef-db-seed.yaml').read_text())
    bootstrap = yaml.safe_load(app['spec']['source']['helm']['values'])
    assert api['database']['host'] == 'global-postgres-pooler-rw.global.svc.cluster.local'
    assert api['database']['name'] == 'homechef_db'
    assert company['database']['homechef']['host'] == 'global-postgres-rw.global.svc.cluster.local'
    assert company['database']['homechef']['name'] == 'homechef_db'
    assert bootstrap['targets'][0]['host'] == 'global-postgres-rw.global.svc.cluster.local'
    assert bootstrap['targets'][0]['user'] == 'homechef'
    assert not bootstrap.get('suspend', False)
