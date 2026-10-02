import subprocess
from pathlib import Path

import yaml

CHART = Path(__file__).resolve().parents[1] / 'charts/apps/global-valkey'


def test_authenticated_valkey_uses_secret_for_every_connection():
    result = subprocess.run(['helm', 'template', 'ax-valkey', str(CHART), '--set', 'auth.enabled=true,auth.existingSecret=ax-valkey-password,acl.enabled=false'], capture_output=True, text=True, check=True)
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    workloads = [d for d in docs if d['kind'] in ('StatefulSet', 'Deployment')]
    for obj in workloads:
        for container in obj['spec']['template']['spec']['containers']:
            assert any(e.get('valueFrom', {}).get('secretKeyRef', {}).get('name') == 'ax-valkey-password' for e in container.get('env', []))
    config = next(d['data'] for d in docs if d['kind'] == 'ConfigMap' and 'start-valkey.sh' in d['data'])
    assert 'requirepass' in config['start-valkey.sh']
    assert 'masterauth' in config['start-valkey.sh']
    assert 'sentinel auth-pass' in config['start-sentinel.sh']
    haproxy = next(d['data']['haproxy.cfg'] for d in docs if d['kind'] == 'ConfigMap' and 'haproxy.cfg' in d['data'])
    assert 'AUTH' in haproxy and '${VALKEY_PASSWORD}' in haproxy
