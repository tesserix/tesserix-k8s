import json
from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / 'charts/apps/agentgateway-route-sync'


def render(enabled=True, subjects=True):
    args = ['helm', 'template', 'routes', str(CHART), '--set', f'roamieSeed.enabled={str(enabled).lower()}']
    if subjects:
        args += ['--set-string', 'roamieSeed.managerSubject=100']
        for index in range(7):
            args += ['--set-string', f'roamieSeed.specialistSubjects[{index}]={101 + index}']
    else:
        args += ['--set-string', 'roamieSeed.managerSubject=']
    return subprocess.run(args, capture_output=True, text=True)


def test_routes_require_eight_real_distinct_subjects():
    result = render(subjects=False)
    assert result.returncode != 0
    assert 'Roamie' in result.stderr


def test_roamie_routes_are_imported_through_registry_and_bind_exact_subjects():
    result = render()
    assert result.returncode == 0, result.stderr
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    config = next(d for d in docs if d['kind'] == 'ConfigMap' and d['metadata']['name'] == 'roamie-registry-gateway-resources')
    resources = json.loads(config['data']['resources.json'])['items']
    assert len(resources) == 10
    for name, role in [('roamie-agents-access', 'roamie.manager'), ('roamie-mcp-access', 'roamie.manager'), ('roamie-model-access', 'roamie.models')]:
        policy = next(d for d in resources if d['metadata']['name'] == name)
        traffic = policy['spec']['traffic']
        assert traffic['jwtAuthentication']['mode'] == 'Strict'
        expression = ' '.join(traffic['authorization']['policy']['matchExpressions'])
        assert 'jwt.sub' in expression and '"100"' in expression
        assert '386377229942128837' in expression and role in expression
        if role == 'roamie.models':
            assert all(f'"{i}"' in expression for i in range(101,108))
        else:
            assert '"101"' not in expression
    assert not any(d['kind'] in ['HTTPRoute', 'AgentgatewayBackend', 'AgentgatewayPolicy'] and d['metadata']['name'].startswith('roamie') for d in docs)
    job = next(d for d in docs if d['kind'] == 'Job' and d['metadata']['name'] == 'roamie-registry-gateway-seed')
    script = job['spec']['template']['spec']['containers'][0]['args'][0]
    assert '/v0/agentgateway/import' in script


def test_roamie_route_import_can_be_disabled_without_direct_crs():
    result = render(enabled=False)
    assert result.returncode == 0
    assert 'name: roamie-registry-gateway-seed' not in result.stdout


def test_upstream_secrets_bind_gateway_to_the_same_workload_keys():
    result = render()
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    secret = next(d for d in docs if d['kind'] == 'ExternalSecret' and d['metadata']['name'] == 'roamie-agent-upstream')
    assert secret['spec']['data'] == [{'secretKey': 'token', 'remoteRef': {'key': 'prod-roamie-agents-api-key'}}]
    shared = list(yaml.safe_load_all((ROOT / 'external-secrets/prod/agentgateway-system/externalsecret.yaml').read_text()))
    mcp = next(d for d in shared if d and d['metadata']['name'] == 'product-mcp-upstream-keys')
    assert {'secretKey': 'ROAMIE_TRAVEL_MCP_KEY', 'remoteRef': {'key': 'prod-roamie-travel-mcp-key'}} in mcp['spec']['data']


def test_roamie_rejects_duplicate_and_malformed_machine_subjects():
    for subject in ('101', 'not-an-id'):
        args = ['helm', 'template', 'routes', str(CHART), '--set', 'roamieSeed.enabled=true', '--set-string', f'roamieSeed.managerSubject={subject}']
        for index in range(7):
            args += ['--set-string', f'roamieSeed.specialistSubjects[{index}]={101 + index}']
        result = subprocess.run(args, capture_output=True, text=True)
        assert result.returncode != 0
        assert 'Roamie requires' in result.stderr


def test_mcp_transport_is_registry_owned_with_a_separate_upstream_key():
    result = render()
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    config = next(d for d in docs if d['kind']=='ConfigMap' and d['metadata']['name']=='roamie-registry-gateway-resources')
    resources=json.loads(config['data']['resources.json'])['items']
    backend=next(d for d in resources if d['kind']=='AgentgatewayBackend' and d['metadata']['name']=='roamie-roamie-travel-mcp')
    target=backend['spec']['mcp']['targets'][0]['static']
    assert (target['host'],target['port'],target['path']) == ('roamie-travel-mcp.roamie.svc.cluster.local',8080,'/mcp')
    assert target['policies']['auth'] == {'passthrough': {}, 'credentials': [{'secretRef': {'name':'product-mcp-upstream-keys','key':'ROAMIE_TRAVEL_MCP_KEY'}, 'location': {'header': {'name':'X-MCP-Key'}}}]}
    route=next(d for d in resources if d['kind']=='HTTPRoute' and d['metadata']['name']=='roamie-roamie-travel-mcp')
    assert route['spec']['parentRefs'] == [{'name':'agentgateway-mcp','sectionName':'runtime'}]
    assert route['spec']['rules'][0]['matches'][0]['path']['value']=='/mcp/roamie/roamie-travel-mcp'
