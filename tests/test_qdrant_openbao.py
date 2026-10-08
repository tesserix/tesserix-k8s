import json
import re

import yaml
from test_homechef_openbao_access import ROOT, render, resource


def test_qdrant_reader_is_exact_read_only_and_namespace_bound():
    config = resource(render('charts/thirdparty/openbao'), 'ConfigMap', 'openbao-bootstrap')['data']
    role = json.loads(config['role-read-qdrant-production.json'])
    assert role['bound_service_account_names'] == ['qdrant']
    assert role['bound_service_account_namespaces'] == ['ai-database']
    policy = config['policy-read-qdrant-production.hcl']
    assert re.findall(r'path "([^"]+)"', policy) == [
        'kv/data/qdrant/app/qdrant-api-key',
        'kv/data/qdrant/app/qdrant-read-only-api-key',
    ]
    assert re.findall(r'capabilities = \[([^]]+)\]', policy) == ['"read"', '"read"']


def test_qdrant_keys_use_openbao_without_changing_consumed_names():
    docs = render('charts/thirdparty/qdrant')
    es = resource(docs, 'ExternalSecret', 'qdrant-api-keys')['spec']
    assert es['secretStoreRef'] == {'name': 'openbao-qdrant-production', 'kind': 'SecretStore'}
    assert es['target']['name'] == 'qdrant-api-keys'
    assert es['data'] == [
        {'secretKey': 'api-key', 'remoteRef': {'key': 'qdrant/app/qdrant-api-key', 'property': 'value'}},
        {'secretKey': 'read-only-api-key', 'remoteRef': {'key': 'qdrant/app/qdrant-read-only-api-key', 'property': 'value'}},
    ]
    store = resource(docs, 'SecretStore', 'openbao-qdrant-production')
    assert store['spec']['provider']['vault']['auth']['kubernetes'] == {
        'mountPath': 'kubernetes', 'role': 'read-qdrant-production',
        'serviceAccountRef': {'name': 'qdrant'},
    }
