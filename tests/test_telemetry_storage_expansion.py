import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).parents[1]


@pytest.mark.parametrize('chart,prefix,count,original,expanded', [
    ('redpanda', 'data', 3, '40Gi', '80Gi'),
    ('otel-gateway', 'queue', 2, '20Gi', '40Gi'),
])
def test_existing_claims_expand_without_replacing_statefulsets(chart, prefix, count, original, expanded):
    docs = list(yaml.safe_load_all(subprocess.check_output([
        'helm', 'template', chart, str(ROOT / 'charts/thirdparty' / chart),
        '--namespace', 'observability',
    ], text=True)))
    statefulset = next(d for d in docs if d and d['kind'] == 'StatefulSet')
    assert statefulset['spec']['volumeClaimTemplates'][0]['spec']['resources']['requests']['storage'] == original
    claims = [d for d in docs if d and d['kind'] == 'PersistentVolumeClaim']
    assert {c['metadata']['name'] for c in claims} == {f'{prefix}-{chart}-{i}' for i in range(count)}
    for claim in claims:
        assert claim['metadata']['namespace'] == 'observability'
        assert claim['spec']['resources']['requests']['storage'] == expanded
        assert claim['spec']['accessModes'] == ['ReadWriteOnce']
        assert claim['spec']['storageClassName'] == statefulset['spec']['volumeClaimTemplates'][0]['spec']['storageClassName']
        assert 'volumeName' not in claim['spec']
        options = claim['metadata']['annotations']['argocd.argoproj.io/sync-options']
        assert 'Prune=false' in options and 'Delete=false' in options
        assert 'Force=true' not in options and 'Replace=true' not in options
