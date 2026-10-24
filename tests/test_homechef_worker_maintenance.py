import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_explicit_zero_worker_replicas_stops_database_writes():
    result = subprocess.run(['helm', 'template', 'homechef-api', str(ROOT / 'charts/apps/homechef-api'), '--set', 'temporal.worker.replicas=0'], check=True, capture_output=True, text=True)
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    worker = next(d for d in docs if d['kind'] == 'Deployment' and d['metadata']['name'].endswith('-temporal-worker'))
    assert worker['spec']['replicas'] == 0


def test_production_replica_intent_survives_kargo_image_parameter_ownership():
    for chart in ('homechef-api', 'company'):
        app_path = 'homechef/homechef-api.yaml' if chart == 'homechef-api' else 'global/company.yaml'
        app = yaml.safe_load((ROOT / 'argocd/prod/apps' / app_path).read_text())
        paused = chart == 'homechef-api'
        assert all(p['name'] != 'replicaCount' for p in app['spec']['source']['helm']['parameters'])
        chart_path = ROOT / 'charts/apps' / chart
        result = subprocess.run(
            ['helm', 'template', chart, str(chart_path), '--namespace', 'homechef' if chart == 'homechef-api' else 'tesserix', '-f', str(chart_path / 'values-prod.yaml'), '--set', 'image.tag=verified-release'],
            check=True, capture_output=True, text=True,
        )
        docs = [d for d in yaml.safe_load_all(result.stdout) if d]
        deployments = [d for d in docs if d['kind'] == 'Deployment']
        assert deployments
        for deployment in deployments:
            expected = 0 if paused else (1 if deployment['metadata']['name'].endswith('-temporal-worker') else 2)
            assert deployment['spec']['replicas'] == expected
        if paused:
            assert not any(d['kind'] in ('ScaledObject', 'HorizontalPodAutoscaler') for d in docs)
