import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).parents[1]


def test_ingest_rollout_loads_normalized_langfuse_credentials():
    documents = yaml.safe_load_all(subprocess.check_output([
        'helm', 'template', 'otel-ingest',
        str(ROOT / 'charts/thirdparty/otel-ingest'),
    ], text=True))
    deployment = next(doc for doc in documents if doc and doc['kind'] == 'Deployment')
    assert deployment['spec']['template']['metadata']['annotations'].get(
        'kora.tesserix.app/secret-source'
    ) == 'openbao-v1'
