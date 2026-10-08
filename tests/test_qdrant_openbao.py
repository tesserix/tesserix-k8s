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


def test_devai_shared_key_follows_same_openbao_source():
    docs = list(yaml.safe_load_all((ROOT / 'external-secrets/prod/devai/externalsecret.yaml').read_text()))
    item = next(item for doc in docs if doc and doc.get('kind') == 'ExternalSecret' for item in doc['spec'].get('data', []) if item['secretKey'] == 'DEVAI_QDRANT_API_KEY')
    assert item['remoteRef'] == {'key': 'qdrant/app/qdrant-api-key', 'property': 'value'}
    assert item['sourceRef']['storeRef'] == {'name': 'openbao-qdrant', 'kind': 'SecretStore'}
    config = resource(render('charts/thirdparty/openbao'), 'ConfigMap', 'openbao-bootstrap')['data']
    role = json.loads(config['role-read-qdrant-devai.json'])
    assert role['bound_service_account_namespaces'] == ['devai']
    assert role['bound_service_account_names'] == ['devai-production-reader']
    assert config['policy-read-qdrant-devai.hcl'].strip() == 'path "kv/data/qdrant/app/qdrant-api-key" { capabilities = ["read"] }'


def test_qdrant_identity_exists_before_secretstore_on_cold_start():
    docs = render('charts/thirdparty/qdrant')
    identity = resource(docs, 'ServiceAccount', 'qdrant')
    store = resource(docs, 'SecretStore', 'openbao-qdrant-production')
    assert int(identity['metadata'].get('annotations', {}).get('argocd.argoproj.io/sync-wave', '0')) < int(store['metadata']['annotations']['argocd.argoproj.io/sync-wave'])
