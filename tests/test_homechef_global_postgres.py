import json
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart):
    result = subprocess.run(['helm', 'template', 'check', str(ROOT / chart)],
                            check=True, capture_output=True, text=True)
    return [d for d in yaml.safe_load_all(result.stdout) if d]


def test_homechef_destination_preserves_role_isolation_and_standby():
    docs = render('charts/apps/global-postgres')
    cluster = next(d['spec'] for d in docs if d['kind'] == 'Cluster')
    assert cluster['instances'] == 2
    assert cluster['maxSyncReplicas'] == 1
    assert cluster['affinity']['podAntiAffinityType'] == 'required'
    roles = {r['name']: r for r in cluster['managed']['roles']}
    for name in ('homechef', 'homechef_platform_admin'):
        assert roles[name]['login']
        assert not roles[name].get('superuser', False)
        assert not roles[name].get('createdb', False)
        assert not roles[name].get('createrole', False)
        assert roles[name]['passwordSecret']['name'] == 'global-postgres-' + name.replace('_', '-')
    db = next(d['spec'] for d in docs if d['kind'] == 'Database' and d['spec']['name'] == 'homechef_db')
    assert db['owner'] == 'homechef'
    assert db['databaseReclaimPolicy'] == 'retain'


def test_homechef_destination_reader_has_only_two_credentials():
    docs = render('charts/thirdparty/openbao')
    config = next(d['data'] for d in docs if d['kind'] == 'ConfigMap' and d['metadata']['name'] == 'openbao-bootstrap')
    policy = config['policy-read-homechef-global.hcl']
    assert policy.count('path ') == 2
    for key in ('postgresql-password', 'platform-admin-password'):
        assert f'path "kv/data/homechef/homechef-api/fe3dr-{key}" {{ capabilities = ["read"] }}' in policy
    role = json.loads(config['role-read-homechef-global.json'])
    assert role['bound_service_account_namespaces'] == ['global']
    assert role['bound_service_account_names'] == ['homechef-database-reader']


def test_destination_secrets_are_openbao_scoped_and_reloadable():
    docs = list(yaml.safe_load_all((ROOT / 'external-secrets/prod/global/homechef-database.yaml').read_text()))
    store = next(d for d in docs if d['kind'] == 'SecretStore')
    auth = store['spec']['provider']['vault']['auth']['kubernetes']
    assert auth['role'] == 'read-homechef-global'
    assert auth['serviceAccountRef']['name'] == 'homechef-database-reader'
    secrets = [d for d in docs if d['kind'] == 'ExternalSecret']
    assert len(secrets) == 2
    for secret in secrets:
        spec = secret['spec']
        assert spec['secretStoreRef'] == {'name': 'openbao-homechef-database', 'kind': 'SecretStore'}
        assert spec['target']['deletionPolicy'] == 'Retain'
        assert spec['target']['template']['metadata']['labels']['cnpg.io/reload'] == 'true'
        assert spec['data'][0]['remoteRef']['property'] == 'value'
