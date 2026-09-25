import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_cnpg_ports_are_allowed_without_http_attributes():
    rendered = subprocess.check_output(
        ['helm', 'template', 'roamie-postgres', str(ROOT / 'charts/apps/roamie-postgres')],
        text=True,
    )
    policies = [doc for doc in yaml.safe_load_all(rendered)
                if doc and doc.get('kind') == 'AuthorizationPolicy']
    assert len(policies) == 1, 'CNPG needs an L4 allow policy in the ambient namespace'
    spec = policies[0]['spec']
    assert spec['selector']['matchLabels'] == {'cnpg.io/cluster': 'roamie-postgres'}
    assert spec['action'] == 'ALLOW'
    assert spec['rules'] == [{'to': [{'operation': {'ports': ['5432', '8000', '9187']}}]}]
