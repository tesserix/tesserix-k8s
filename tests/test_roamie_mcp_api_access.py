from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_mcp_api_access_is_configured_without_enabling_customer_manager():
    docs = list(yaml.safe_load_all(subprocess.check_output(
        ['helm', 'template', 'roamie-api', str(ROOT/'charts/apps/roamie-api')], text=True)))
    deployment = next(d for d in docs if d and d['kind'] == 'Deployment')
    env = {e['name']: e for e in deployment['spec']['template']['spec']['containers'][0]['env']}
    assert 'TRIP_MANAGER_ORIGIN' not in env
    assert env['TRAVEL_MCP_API_KEY']['valueFrom']['secretKeyRef']['key'] == 'travel_mcp_api_key'
    secret = next(d for d in docs if d and d['kind'] == 'ExternalSecret')
    data = {e['secretKey']: e['remoteRef']['key'] for e in secret['spec']['data']}
    assert data['travel_mcp_api_key'] == 'prod-roamie-mcp-api-token'
