from test_kora_ai_gateway_manifests import render_chart, resource


def test_production_api_has_complete_ocr_configuration():
    docs = render_chart('charts/apps/kora-api', 'kora-api', 'kora', 'values-prod.yaml')
    deployment = resource(docs, 'Deployment', 'kora-api')
    env = {x['name']: x for x in deployment['spec']['template']['spec']['containers'][0]['env']}
    assert env['OCR_UPLOAD_URL']['value'] == 'http://document-intelligence-prod-upload-api.document-intelligence.svc.cluster.local:8080'
    assert env['OCR_JOB_URL']['value'] == 'http://document-intelligence-prod-job-api.document-intelligence.svc.cluster.local:8080'
    assert env['OCR_KEY_ID']['value'] == 'kora-prod-v1'
    assert env['OCR_TENANT']['value'] == 'ten_kora_prod'
    assert env['OCR_KEY_SECRET']['valueFrom']['secretKeyRef'] == {'name': 'kora-ocr-client', 'key': 'signing-key'}
    secret = resource(docs, 'ExternalSecret', 'kora-ocr-client')['spec']
    assert secret['secretStoreRef'] == {'name': 'openbao-kora-production', 'kind': 'SecretStore'}
    assert secret['data'][0]['remoteRef'] == {'key': 'kora/app/kora-ocr-workload-identity-keys', 'property': 'value'}
    assert set(secret['target']['template']['data']) == {'signing-key'}
    assert secret['target']['template']['mergePolicy'] == 'Replace'
    template = secret['target']['template']['data']['signing-key']
    assert 'kora-prod-v1=kora:' in template
    assert 'fail' in template


def test_ocr_network_access_is_scoped_to_kora_api_and_production_apis():
    docs = render_chart('charts/apps/kora-api', 'kora-api', 'kora', 'values-prod.yaml')
    policy = resource(docs, 'NetworkPolicy', 'kora-ocr-egress')['spec']
    assert policy['podSelector']['matchLabels']['app.kubernetes.io/name'] == 'kora-api'
    peer = policy['egress'][0]['to'][0]
    assert peer['namespaceSelector']['matchLabels'] == {'kubernetes.io/metadata.name': 'document-intelligence'}
    assert peer['podSelector']['matchLabels'] == {'app.kubernetes.io/instance': 'document-intelligence-prod'}
    assert peer['podSelector']['matchExpressions'] == [{'key': 'app.kubernetes.io/component', 'operator': 'In', 'values': ['upload-api', 'job-api']}]
    assert {x['port'] for x in policy['egress'][0]['ports']} == {8080, 15008}
    ocr = render_chart('charts/apps/document-intelligence', 'document-intelligence-prod', 'document-intelligence', 'values-prod.yaml')
    for component in ('upload-api', 'job-api'):
        auth = resource(ocr, 'AuthorizationPolicy', f'document-intelligence-prod-{component}-clients')['spec']
        assert auth['rules'][0]['from'][0]['source']['principals'] == ['cluster.local/ns/kora/sa/kora-api']


def test_ocr_secret_template_extracts_only_kora_and_rejects_missing_key(tmp_path):
    import json
    import subprocess
    import yaml

    docs = render_chart('charts/apps/kora-api', 'kora-api', 'kora', 'values-prod.yaml')
    template = resource(docs, 'ExternalSecret', 'kora-ocr-client')['spec']['target']['template']['data']['signing-key']
    (tmp_path / 'Chart.yaml').write_text('apiVersion: v2\nname: secret-template-test\nversion: 0.1.0\n')
    (tmp_path / 'templates').mkdir()
    (tmp_path / 'templates' / 'result.yaml').write_text('value: {{ tpl .Values.template (dict "identities" .Values.identities) | quote }}\n')
    for identities, expected in [
        ('kora-prod-v1=kora:' + 'a' * 64, 'a' * 64),
        ('other-v1=other:' + 'b' * 64 + ',kora-prod-v1=kora:' + 'a' * 64 + ',other-v2=other:' + 'c' * 64, 'a' * 64),
        ('other-v1=other:' + 'b' * 64, None),
        ('kora-prod-v1=kora:bad', None),
        ('kora-prod-v1=other:' + 'a' * 64, None),
    ]:
        values = tmp_path / 'values.json'
        values.write_text(json.dumps({'template': template, 'identities': identities}))
        result = subprocess.run(['helm', 'template', 'test', str(tmp_path), '-f', str(values)], capture_output=True, text=True)
        if expected is None:
            assert result.returncode != 0
            assert 'Kora production OCR signing key missing or invalid' in result.stderr
        else:
            assert result.returncode == 0, result.stderr
            assert yaml.safe_load(result.stdout)['value'] == expected


def test_firebase_account_status_key_is_required_and_openbao_backed():
    docs = render_chart('charts/apps/kora-api', 'kora-api', 'kora', 'values-prod.yaml')
    deployment = resource(docs, 'Deployment', 'kora-api')
    env = {x['name']: x for x in deployment['spec']['template']['spec']['containers'][0]['env']}
    assert env['FIREBASE_API_KEY']['valueFrom']['secretKeyRef'] == {'name': 'kora-firebase-client', 'key': 'api-key'}
    secret = resource(docs, 'ExternalSecret', 'kora-firebase-client')['spec']
    assert secret['secretStoreRef'] == {'name': 'openbao-kora-production', 'kind': 'SecretStore'}
    assert secret['data'] == [{'secretKey': 'api-key', 'remoteRef': {'key': 'kora/app/kora-firebase-api-key', 'property': 'value'}}]
