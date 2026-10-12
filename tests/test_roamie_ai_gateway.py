import json
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).parents[1]
CHART = ROOT / 'charts/apps/roamie-ai-gateway'


def render(rollback=False):
    command = ['helm', 'template', 'roamie-ai-gateway', str(CHART), '-n', 'agentgateway-system']
    if rollback:
        command += ['--set', 'registryOwnership.enabled=false']
    return [d for d in yaml.safe_load_all(subprocess.check_output(command, text=True)) if d]


def test_api_uses_private_gateway_and_never_receives_provider_key():
    values = yaml.safe_load((ROOT / 'charts/apps/roamie-api/values.yaml').read_text())
    assert values['env']['AI_GATEWAY_ORIGIN'] == 'http://roamie-ai.agentgateway-system.svc.cluster.local:8080'
    assert 'JEV_API_KEY' not in values['secretEnv']
    assert 'jev_api_key' not in values['secrets']


def test_gateway_requires_mobile_jwt_and_api_workload_and_records_console_identity():
    docs = render(True)
    auth = next(d for d in docs if d['kind'] == 'AuthorizationPolicy')
    rule = auth['spec']['rules'][0]
    assert rule['from'][0]['source']['principals'] == ['cluster.local/ns/roamie/sa/roamie-api']
    assert rule['to'][0]['operation']['paths'] == ['/v1/chat/completions', '/v1/decisions', '/v1/speech']
    policy = next(d for d in docs if d['kind'] == 'AgentgatewayPolicy' and d['metadata']['name'] == 'roamie-api-auth')
    traffic = policy['spec']['traffic']
    assert traffic['jwtAuthentication']['mode'] == 'Strict'
    assert traffic['jwtAuthentication']['providers'][0]['audiences'] == ['392328861469115174']
    assert '392328865646707494' in traffic['authorization']['policy']['matchExpressions'][0]
    assert '392328864774226726' in traffic['authorization']['policy']['matchExpressions'][0]
    trace = next(d for d in docs if d['kind'] == 'AgentgatewayPolicy' and d['metadata']['name'] == 'roamie-api-observability')['spec']['frontend']['tracing']
    assert trace['backendRef']['name'] == 'ai-usage-ingest'
    fields = {a['name']: a['expression'] for a in trace['attributes']['add']}
    assert fields['tesserix.product'] == "'roamie'"
    assert fields['tesserix.service'] == "'roamie-api'"
    assert 'metadata' in fields['tesserix.user_id']
    assert 'tesserix.decision_input_tokens' in fields
    assert 'request.body' not in json.dumps(trace)
    secret = next(d for d in docs if d['kind'] == 'ExternalSecret')
    assert secret['spec']['data'][0]['remoteRef']['key'] == 'roamie/app/roamie-typesafe-api-key'
    assert secret['spec']['secretStoreRef']['name'] == 'openbao-roamie-production'


def test_registry_owns_routes_while_helm_owns_runtime_and_secrets():
    docs = render()
    assert not any(d['kind'] in ['HTTPRoute', 'AgentgatewayBackend', 'AgentgatewayPolicy'] for d in docs)
    payload = json.loads((ROOT / 'charts/apps/agentgateway-route-sync/files/platform-resources.json').read_text())
    assert ('HTTPRoute', 'roamie-api-decide') in {(d['kind'], d['metadata']['name']) for d in payload['items']}


def test_speech_uses_fixed_native_vertex_backend_with_auth_and_bounded_telemetry():
    docs = render(True)
    by_name = {d['metadata']['name']: d for d in docs}
    backend = by_name['roamie-api-speech-vertex']['spec']
    assert backend['static'] == {'host': 'aiplatform.googleapis.com', 'port': 443}
    assert backend['policies']['auth'] == {'gcp': {}}
    route = by_name['roamie-api-speech']['spec']['rules'][0]
    assert route['matches'][0]['path'] == {'type': 'Exact', 'value': '/v1/speech'}
    rewrite = route['filters'][0]['urlRewrite']
    assert rewrite['path']['replaceFullPath'].endswith('/models/gemini-3.8-flash-tts:generateContent')
    assert {'name': 'Authorization'} != route['filters'][1]['requestHeaderModifier'].get('set', [{}])[0]
    assert 'Authorization' in route['filters'][1]['requestHeaderModifier']['remove']
    targets = by_name['roamie-api-auth']['spec']['targetRefs']
    assert any(t['name'] == 'roamie-api-speech' for t in targets)
    traffic = by_name['roamie-api-speech-traffic']['spec']['traffic']
    assert traffic['timeouts']['request'] == '45s'
    assert traffic['buffer']['request']['maxBytes'] == '8Ki'
    assert traffic['buffer']['response']['maxBytes'] == '3Mi'
    assert traffic['buffer']['response']['failureMode'] == 'FailClosed'
    metadata = traffic['transformation']['request']['metadata']
    assert metadata['ledger_user'] == 'jwt.sub'
    assert metadata['speech_model'] == "'gemini-3.8-flash-tts'"
    assert 'response.body' in traffic['transformation']['response']['metadata']['speech_input']


def test_speech_allows_both_app_voices_and_restricts_output_to_audio():
    policy = next(d for d in render(True) if d['metadata']['name'] == 'roamie-api-speech-traffic')
    expressions = policy['spec']['traffic']['authorization']['policy']['matchExpressions']
    assert expressions == [
        'json(request.body).generationConfig.responseModalities == ["AUDIO"] && '
        'json(request.body).generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName in ["Sulafat", "Algieba"]'
    ]
