"""Every SandboxDataSync claim must have its data plane wired in this repo.

The operator only materialises a CronJob; the job fails at runtime if the
referenced Secret has no ExternalSecret, or if the target schema is missing
from the devai_evals_db snapshot. Both failures are silent until 02:00 UTC.
"""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CLAIMS_DIR = ROOT / "k8s/operators/db-anonymise/claims"
EVALS_SQL = (
    ROOT / "charts/apps/db-schema-bootstrap/schemas/global/global/devai_evals_db.sql"
).read_text()


def _claims():
    for path in sorted(CLAIMS_DIR.glob("*.yaml")):
        if path.name == "kustomization.yaml":
            continue
        for doc in yaml.safe_load_all(path.read_text()):
            if doc and doc.get("kind") == "SandboxDataSync":
                yield path, doc


def test_claims_exist() -> None:
    assert list(_claims()), "no SandboxDataSync claims found"


def test_every_claim_secret_has_an_externalsecret() -> None:
    for path, claim in _claims():
        namespace = claim["metadata"]["namespace"]
        secret_names = {
            claim["spec"]["source"]["secretRef"]["name"],
            claim["spec"]["target"]["secretRef"]["name"],
            claim["spec"]["anonymizationSaltSecretRef"]["name"],
        }
        es_dir = ROOT / "external-secrets/prod" / namespace
        rendered = set()
        for es_file in es_dir.glob("*.yaml"):
            for doc in yaml.safe_load_all(es_file.read_text()):
                if doc and doc.get("kind") == "ExternalSecret":
                    rendered.add(doc["spec"]["target"]["name"])
        missing = secret_names - rendered
        assert not missing, f"{path.name}: no ExternalSecret renders {missing}"


def test_every_claim_target_table_is_provisioned_in_evals_snapshot() -> None:
    for path, claim in _claims():
        for table in claim["spec"]["tables"]:
            schema, name = table["target"].split(".", 1)
            assert f"CREATE SCHEMA IF NOT EXISTS {schema}" in EVALS_SQL, (
                f"{path.name}: schema {schema} missing from devai_evals_db.sql"
            )
            assert f"CREATE TABLE IF NOT EXISTS {schema}.{name}" in EVALS_SQL, (
                f"{path.name}: table {table['target']} missing from devai_evals_db.sql"
            )
