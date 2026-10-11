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


def test_only_database_pods_can_use_gke_backup_identity():
    result = subprocess.run(['helm', 'template', 'planning-poker-postgres', str(ROOT / 'charts/apps/planning-poker-postgres')], check=True, capture_output=True, text=True)
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    policy = next(d['spec'] for d in docs if d['kind'] == 'NetworkPolicy' and d['metadata']['name'] == 'planning-poker-postgres-backup-identity')
    assert policy['podSelector'] == {'matchLabels': {'cnpg.io/cluster': 'planning-poker-postgres'}}
    endpoints = {(peer['ipBlock']['cidr'], port['port']) for rule in policy['egress'] for peer in rule['to'] for port in rule['ports']}
    assert endpoints == {('169.254.169.254/32', 80), ('169.254.169.252/32', 988)}
    scheduled = next(d for d in docs if d['kind'] == 'ScheduledBackup')
    assert scheduled['spec']['immediate'] is True
