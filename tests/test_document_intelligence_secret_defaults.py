import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).parents[1]
CHART = ROOT / "charts/apps/document-intelligence"


def render(*args):
    result = subprocess.run(
        ["helm", "template", "example", str(CHART), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return [
        d
        for d in yaml.safe_load_all(result.stdout)
        if d and d["kind"] == "ExternalSecret"
    ]


def test_new_product_defaults_to_scoped_openbao():
    docs = render("--set", "product=demo,environment=prod")
    assert len(docs) == 2
    for doc in docs:
        assert doc["spec"]["secretStoreRef"] == {
            "kind": "SecretStore",
            "name": "openbao-demo-production",
        }
        for item in doc["spec"]["data"]:
            assert item["remoteRef"]["key"].startswith("demo/app/demo-")
            assert item["remoteRef"]["property"] == "value"


def test_existing_database_readers_remain_explicit_until_migration():
    for env, prefix in [("prod", "prod"), ("sandbox", "dev")]:
        docs = render("-f", str(CHART / f"values-{env}.yaml"))
        db = next(d for d in docs if d["metadata"]["name"].endswith("-db"))
        assert db["spec"]["secretStoreRef"] == {
            "kind": "ClusterSecretStore",
            "name": "gcp-secret-store",
        }
        assert db["spec"]["data"][0]["remoteRef"] == {
            "key": f"{prefix}-document-intelligence-db-password"
        }
