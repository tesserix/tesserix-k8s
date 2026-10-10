import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_planning_poker_archives_before_reducing_redundancy():
    result = subprocess.run(['helm', 'template', 'planning-poker-postgres', str(ROOT / 'charts/apps/planning-poker-postgres')], check=True, capture_output=True, text=True)
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    cluster = next(d['spec'] for d in docs if d['kind'] == 'Cluster')
    assert cluster['backup']['barmanObjectStore']['destinationPath'] == 'gs://tesseract-prod-backups-in/planning-poker-postgres'
    assert cluster['backup']['retentionPolicy'] == '3d'
    assert cluster['affinity']['podAntiAffinityType'] == 'required'
    assert any(d['kind'] == 'ScheduledBackup' for d in docs)
