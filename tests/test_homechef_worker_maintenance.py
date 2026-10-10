import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_explicit_zero_worker_replicas_stops_database_writes():
    result = subprocess.run(['helm', 'template', 'homechef-api', str(ROOT / 'charts/apps/homechef-api'), '--set', 'temporal.worker.replicas=0'], check=True, capture_output=True, text=True)
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    worker = next(d for d in docs if d['kind'] == 'Deployment' and d['metadata']['name'].endswith('-temporal-worker'))
    assert worker['spec']['replicas'] == 0
