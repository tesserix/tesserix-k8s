from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart):
    return [d for d in yaml.safe_load_all(subprocess.check_output(['helm', 'template', 'r', str(ROOT / chart)], text=True)) if d]


def test_public_ocr_sandbox_is_retired():
    assert not (ROOT / 'charts/apps/ocr-public-sandbox').exists()
    assert not (ROOT / 'argocd/prod/infrastructure/ocr-public-sandbox.yaml').exists()
    releases = [yaml.safe_load(p.read_text()) for p in (ROOT / 'charts/apps/document-intelligence/products').glob('*.yaml')]
    assert releases and not any(r.get('publicSandbox') for r in releases)


def test_public_ocr_sandbox_databases_and_roles_are_dropped():
    docs = render('charts/apps/global-postgres')
    databases = {d['spec']['name']: d['spec']['ensure'] for d in docs if d['kind'] == 'Database'}
    assert databases['ocr_public_core_db'] == databases['ocr_public_ledger_db'] == 'absent'
    assert databases['document_intelligence_roamie_prod_db'] == 'present'
    cluster = next(d for d in docs if d['kind'] == 'Cluster')
    roles = {r['name']: r for r in cluster['spec']['managed']['roles']}
    for name in ['ocr_public_core', 'ocr_public_ledger']:
        assert roles[name]['ensure'] == 'absent' and 'passwordSecret' not in roles[name], name
        # A spec change is what makes CNPG retry a drop that failed before the databases went.
        assert roles[name]['comment'] == 'retired public OCR sandbox', name
    assert roles['document_intelligence_roamie_prod']['ensure'] == 'present'
    assert roles['document_intelligence_roamie_prod']['comment'] == 'roamie prod document intelligence runtime writer'
