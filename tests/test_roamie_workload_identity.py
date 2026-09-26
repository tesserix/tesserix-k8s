from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart, *settings):
    command = ['helm', 'template', chart, str(ROOT / 'charts/apps' / chart)]
    for setting in settings:
        command.extend(['--set', setting])
    return [doc for doc in yaml.safe_load_all(subprocess.check_output(command, text=True)) if doc]


def test_ai_workloads_have_an_enforced_waypoint_and_refreshing_credentials():
    docs = render('roamie-ai', 'enabled=true', 'profileBoundaryVerified=true', 'registryRoutesVerified=true')
    waypoint = next(d for d in docs if d['kind'] == 'Gateway' and d['metadata']['name'] == 'waypoint')
    assert waypoint['spec']['gatewayClassName'] == 'istio-waypoint'
    assert waypoint['spec']['listeners'] == [{'name': 'mesh', 'port': 15008, 'protocol': 'HBONE'}]
    for name, prefix in [('roamie-trip-manager', 'ROAMIE_MANAGER_'), ('roamie-agents', 'ROAMIE_AGENTS_')]:
        secret = next(d for d in docs if d['kind'] == 'ExternalSecret' and d['metadata']['name'] == name)
        keys = {d['secretKey']: d['remoteRef']['key'] for d in secret['spec']['data']}
        assert prefix + 'GATEWAY_CLIENTS' in keys
        assert keys[prefix + 'DELEGATION_KEY'] == 'prod-roamie-delegation-key'
        assert prefix + 'GATEWAY_API_KEY' not in keys
        assert prefix + 'WORKER_API_KEY' not in keys


def test_api_and_manager_share_stable_personal_identity_key():
    docs = render('roamie-api', 'tripManager.enabled=true')
    keys = {item['secretKey']: item['remoteRef']['key'] for doc in docs if doc['kind'] == 'ExternalSecret' for item in doc['spec'].get('data', [])}
    assert keys['TRIP_MANAGER_IDENTITY_KEY'] == 'prod-roamie-manager-identity-key'


def test_unverified_ai_configuration_remains_disabled():
    assert render('roamie-ai') == []


def test_mcp_uses_the_verified_cluster_and_zitadel_boundary():
    docs = render('roamie-ai', 'enabled=true', 'profileBoundaryVerified=true', 'registryRoutesVerified=true')
    deployment = next(d for d in docs if d['kind'] == 'Deployment' and d['metadata']['name'] == 'roamie-travel-mcp')
    env = {e['name']: e['value'] for e in deployment['spec']['template']['spec']['containers'][0]['env']}
    assert env['ROAMIE_MCP_GATEWAY_CIDRS'] == '10.20.0.0/16'
    assert env['ROAMIE_MCP_ISSUER'] == 'https://auth.tesserix.app'
    assert env['ROAMIE_MCP_AUDIENCE'] == '387190457387450503'
    assert env['ROAMIE_MCP_ORGANIZATION'] == '386377229942128837'


def test_mesh_candidate_uses_published_images_and_internal_mcp_origin():
    values = yaml.safe_load((ROOT / 'charts/apps/roamie-ai/values.yaml').read_text())
    expected = {'roamie-trip-manager': 'sha256:13f494f2a588569021fd5778fb14103880c36fb61842452ad0141b4f982af70e', 'roamie-agents': 'sha256:7fc89787b70f589d5d1f7587f770736f64eebd23e38fd2982b66e1b69b3ab0b2'}
    for name, prefix in [('roamie-trip-manager', 'ROAMIE_MANAGER_'), ('roamie-agents', 'ROAMIE_AGENTS_')]:
        workload = values['workloads'][name]
        assert workload['digest'] == expected[name]
        assert workload['config'][prefix+'MCP_GATEWAY_ORIGIN'] == 'http://agentgateway-mcp.agentgateway-system.svc.cluster.local:8082'


def test_mcp_schema_contract_is_explicit_and_not_a_credential():
    values = yaml.safe_load((ROOT / 'charts/apps/roamie-ai/values.yaml').read_text())
    for name, prefix in [('roamie-trip-manager', 'ROAMIE_MANAGER_'), ('roamie-agents', 'ROAMIE_AGENTS_')]:
        workload = values['workloads'][name]
        assert workload['config'][prefix+'MCP_SCHEMA_DIGEST'] == '975514e8cc220cc78183121a1f4e61efe7a52f431019718dac35aa5ad3226270'
        assert prefix+'MCP_SCHEMA_DIGEST' not in workload['secrets']


def test_validation_workloads_start_but_the_manager_denies_user_traffic():
    docs = render('roamie-ai', 'enabled=true', 'validationOnly=true')
    assert len([d for d in docs if d['kind'] == 'Deployment']) == 3
    manager = next(d for d in docs if d['kind'] == 'AuthorizationPolicy' and d['metadata']['name'] == 'roamie-trip-manager')
    assert manager['spec']['action'] == 'DENY'
    assert manager['spec']['rules'] == [{}]
    for name in ['roamie-agents', 'roamie-travel-mcp']:
        policy = next(d for d in docs if d['kind'] == 'AuthorizationPolicy' and d['metadata']['name'] == name)
        assert policy['spec']['action'] == 'ALLOW'
        assert policy['spec']['rules'][0]['from'][0]['source']['principals'] == ['cluster.local/ns/agentgateway-system/sa/agentgateway-mcp']


def test_leaving_validation_mode_requires_both_verification_flags():
    for profile, registry in [('false','false'),('true','false'),('false','true')]:
        result = subprocess.run(['helm','template','roamie-ai',str(ROOT / 'charts/apps/roamie-ai'),'--set','enabled=true','--set','validationOnly=false','--set',f'profileBoundaryVerified={profile}','--set',f'registryRoutesVerified={registry}'],capture_output=True,text=True)
        assert result.returncode != 0
        assert 'must be verified' in result.stderr


def test_roamie_workloads_accept_only_waypoint_transport_identity():
    resources = render("roamie-ai", "enabled=true", "validationOnly=true")
    policies = {d['metadata']['name']: d for d in resources if d['kind'] == 'AuthorizationPolicy'}
    for name in ('roamie-trip-manager', 'roamie-agents', 'roamie-travel-mcp'):
        policy = policies[name + '-waypoint-transport']['spec']
        assert policy['selector']['matchLabels'] == {'app.kubernetes.io/name': name}
        assert policy['rules'][0]['from'][0]['source']['principals'] == ['cluster.local/ns/roamie/sa/waypoint']
        assert policy['rules'][0]['to'][0]['operation']['ports'] == ['8080']
    assert policies['roamie-trip-manager']['spec']['action'] == 'DENY'


def test_weather_and_entry_have_separate_model_only_identities():
    text = (ROOT / 'charts/apps/zitadel-bootstrap/values.yaml').read_text()
    for name in ('roamie-weather', 'roamie-entry-guidance'):
        assert 'username: ' + name in text
        assert 'login: ' + name + '\n          roles: [roamie.models]' in text
    values = yaml.safe_load((ROOT / 'charts/apps/roamie-ai/values.yaml').read_text())
    assert values['workloads']['roamie-trip-manager']['secrets']['ROAMIE_MANAGER_WEATHER_API_KEY'] == 'prod-homechef-google-weather-api-key'
    assert 'ROAMIE_AGENTS_WEATHER_API_KEY' not in values['workloads']['roamie-agents']['secrets']


def test_validation_access_is_opt_in_and_preserves_api_only_identity():
    default = render('roamie-ai', 'enabled=true', 'validationOnly=true')
    policy = next(doc for doc in default if doc and doc.get('kind') == 'AuthorizationPolicy' and doc['metadata']['name'] == 'roamie-trip-manager')
    assert policy['spec']['action'] == 'DENY'
    validation = render('roamie-ai', 'enabled=true', 'validationOnly=true', 'validationApiAccess=true')
    policy = next(doc for doc in validation if doc and doc.get('kind') == 'AuthorizationPolicy' and doc['metadata']['name'] == 'roamie-trip-manager')
    assert policy['spec']['action'] == 'ALLOW'
    assert policy['spec']['rules'][0]['from'][0]['source']['principals'] == ['cluster.local/ns/roamie/sa/roamie-api']
