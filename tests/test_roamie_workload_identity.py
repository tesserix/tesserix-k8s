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
