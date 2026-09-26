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
    expected = {'roamie-trip-manager': 'sha256:577572a975df94729ad82523f1c0f316e736a366fbe8818917e31d5f3ced1255', 'roamie-agents': 'sha256:4746b726f9641910db037cd98e7ae90798f431644f4054484b82f02207981f6d'}
    for name, prefix in [('roamie-trip-manager', 'ROAMIE_MANAGER_'), ('roamie-agents', 'ROAMIE_AGENTS_')]:
        workload = values['workloads'][name]
        assert workload['digest'] == expected[name]
        assert workload['config'][prefix+'MCP_GATEWAY_ORIGIN'] == 'http://agentgateway-mcp.agentgateway-system.svc.cluster.local:8082'


def test_mcp_schema_contract_is_explicit_and_not_a_credential():
    values = yaml.safe_load((ROOT / 'charts/apps/roamie-ai/values.yaml').read_text())
    for name, prefix in [('roamie-trip-manager', 'ROAMIE_MANAGER_'), ('roamie-agents', 'ROAMIE_AGENTS_')]:
        workload = values['workloads'][name]
        assert workload['config'][prefix+'MCP_SCHEMA_DIGEST'] == '840c0cd115f52ce031f71bb806770d6612becf4b6097852e7d091c8b2baac015'
        assert prefix+'MCP_SCHEMA_DIGEST' not in workload['secrets']
