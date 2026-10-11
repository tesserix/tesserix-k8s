from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_public_sandbox_is_isolated_and_closed_by_default():
    release = yaml.safe_load((ROOT / 'charts/apps/document-intelligence/products/ocr-sandbox-prod.yaml').read_text())
    assert release['product'] == 'ocr-sandbox'
    assert release['publicSandbox'] is True
    assert set(release['retentionDays'].values()) == {1}
    assert release['database']['user'] == 'ocr_public_core'
    assert release['clients'] == [{'namespace': 'document-intelligence', 'serviceAccount': 'ocr-public-sandbox', 'keyId': 'sandbox-v1', 'openbaoKey': 'ocr-sandbox/app/ocr-sandbox-workload-key', 'openbaoStore': 'openbao-ocr-sandbox-production'}]
    docs = list(yaml.safe_load_all(subprocess.check_output(['helm', 'template', 'ocr-public-sandbox', str(ROOT / 'charts/apps/ocr-public-sandbox'), '--namespace', 'document-intelligence'], text=True)))
    deployment = next(d for d in docs if d and d['kind'] == 'Deployment')
    env = {e['name']: e.get('value') for e in deployment['spec']['template']['spec']['containers'][0]['env']}
    assert env['SANDBOX_ADMISSION_ENABLED'] == 'false'
    assert env['SANDBOX_DAILY_UPLOADS'] == '100'
    assert 'document-intelligence-ocr-sandbox-prod' in env['SANDBOX_UPLOAD_API']
    assert all(b.startswith('ocr-sandbox-') for b in env['SANDBOX_BUCKETS'].split(','))
    assert deployment['spec']['replicas'] == 2
    edge = next(d for d in docs if d and d['kind'] == 'EnvoyFilter')
    route = next(p for p in edge['spec']['configPatches'] if p['applyTo'] == 'HTTP_ROUTE')
    assert route['match']['routeConfiguration']['vhost']['name'] == 'ocr-test.tesserix.app:80'
    assert route['patch']['value']['typed_per_filter_config']['envoy.filters.http.jwt_authn']['disabled'] is True
    policy = next(d for d in docs if d and d['metadata']['name'] == 'allow-ocr-public-sandbox-host')
    assert policy['spec']['rules'][0]['to'][0]['operation']['hosts'] == ['ocr-test.tesserix.app']
    assert any(d and d['kind'] == 'PodDisruptionBudget' for d in docs)


def test_sandbox_storage_and_database_privileges_are_separate():
    source = (ROOT / 'terraform-new/stacks/15-document-intelligence-products/main.tf').read_text()
    assert 'public_sandbox_cleanup' in source
    assert 'soft_delete_policy' in source
    schema = (ROOT / 'charts/apps/db-schema-bootstrap/schemas/global/global/ocr_public_ledger_db.sql').read_text()
    assert 'TO ocr_public_ledger' in schema
    assert 'TO document_intelligence' not in schema
    core = (ROOT / 'charts/apps/db-schema-bootstrap/schemas/global/global/ocr_public_core_db.sql').read_text()
    assert 'TO ocr_public_core' in core
    assert 'TO document_intelligence;' not in core


def test_secret_bootstrap_creates_only_missing_keys_with_cas(monkeypatch):
    import io
    import json
    import runpy
    import urllib.request
    import urllib.error
    import builtins

    writes = []
    original_open = builtins.open

    def fake_open(path, *args, **kwargs):
        if path == '/var/run/secrets/kubernetes.io/serviceaccount/token':
            return io.StringIO('synthetic-jwt')
        return original_open(path, *args, **kwargs)

    def respond(req, timeout):
        assert timeout == 20
        path = req.full_url.split('/v1/', 1)[1]
        payload = json.loads(req.data) if req.data else None
        if path == 'auth/kubernetes/login':
            assert payload['role'] == 'ocr-sandbox-bootstrap'
            return io.BytesIO(b'{"auth":{"client_token":"synthetic-token"}}')
        if path == 'auth/token/revoke-self':
            return io.BytesIO(b'{}')
        assert path.startswith('kv/data/ocr-sandbox/app/ocr-sandbox-')
        if payload is None:
            if path.endswith('core-db-password'):
                return io.BytesIO(b'{"data":{"data":{"value":"existing"}}}')
            raise urllib.error.HTTPError(req.full_url, 404, 'missing', {}, None)
        assert not path.endswith('core-db-password')
        assert payload['options'] == {'cas': 0}
        assert len(payload['data']['value']) == 64
        writes.append(path)
        return io.BytesIO(b'{}')

    monkeypatch.setattr(builtins, 'open', fake_open)
    monkeypatch.setattr(urllib.request, 'urlopen', respond)
    runpy.run_path(str(ROOT / 'charts/apps/ocr-public-sandbox/files/bootstrap.py'))
    assert len(writes) == 2
