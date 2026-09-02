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
ISTIO_VALUES = yaml.safe_load(
    (ROOT / "charts/thirdparty/istio-config/values.yaml").read_text()
)
GLOBAL_SCHEMA_APP = ROOT / "argocd/prod/apps/global/global-db-schema-bootstrap.yaml"


def _claims():
    for path in sorted(CLAIMS_DIR.glob("*.yaml")):
        if path.name == "kustomization.yaml":
            continue
        for doc in yaml.safe_load_all(path.read_text()):
            if doc and doc.get("kind") == "SandboxDataSync":
                yield path, doc


def _externalsecrets(namespace: str):
    es_dir = ROOT / "external-secrets/prod" / namespace
    for es_file in es_dir.glob("*.yaml"):
        for doc in yaml.safe_load_all(es_file.read_text()):
            if doc and doc.get("kind") == "ExternalSecret":
                yield doc


def _rendered_keys(es: dict) -> set:
    keys = {entry["secretKey"] for entry in es["spec"].get("data", [])}
    template = es["spec"]["target"].get("template", {})
    keys |= set(template.get("data", {}))
    return keys


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


def test_every_claim_is_registered_in_the_claims_kustomization() -> None:
    kustomization = yaml.safe_load((CLAIMS_DIR / "kustomization.yaml").read_text())
    resources = set(kustomization.get("resources", []))
    for path, _ in _claims():
        assert path.name in resources, (
            f"{path.name}: not listed in claims/kustomization.yaml — "
            "the CR is never applied and the operator never sees it"
        )


def test_every_claim_secret_provides_the_referenced_keys() -> None:
    for path, claim in _claims():
        namespace = claim["metadata"]["namespace"]
        spec = claim["spec"]
        wanted = [
            spec["source"]["secretRef"],
            spec["target"]["secretRef"],
            spec["anonymizationSaltSecretRef"],
        ]
        rendered = {
            es["spec"]["target"]["name"]: _rendered_keys(es)
            for es in _externalsecrets(namespace)
        }
        for ref in wanted:
            assert ref["key"] in rendered.get(ref["name"], set()), (
                f"{path.name}: no ExternalSecret renders key "
                f"{ref['name']}/{ref['key']}"
            )


def test_every_claim_source_cluster_has_a_sandbox_reader_role() -> None:
    for path, claim in _claims():
        namespace = claim["metadata"]["namespace"]
        role_name = f"{namespace}_sandbox_reader"
        candidates = [
            ROOT / f"charts/apps/{namespace}-postgres/values.yaml",
            ROOT / "charts/apps/global-postgres/values.yaml",
        ]
        role = next(
            (
                entry
                for values_file in candidates
                if values_file.exists()
                for entry in (
                    yaml.safe_load(values_file.read_text()).get("managedRoles") or []
                )
                if entry["name"] == role_name
            ),
            None,
        )
        assert role is not None, (
            f"{path.name}: managed role {role_name} missing from the source "
            "cluster's values.yaml"
        )
        assert "pg_read_all_data" in role.get("inRoles", []), (
            f"{path.name}: {role_name} must read via pg_read_all_data only"
        )
        password_secrets = {
            es["spec"]["target"]["name"] for es in _externalsecrets(namespace)
        }
        assert role["passwordSecret"] in password_secrets, (
            f"{path.name}: no ExternalSecret renders {role['passwordSecret']}"
        )


def test_every_claim_target_schema_is_granted_to_devai_evals() -> None:
    for path, claim in _claims():
        schemas = {table["target"].split(".", 1)[0] for table in claim["spec"]["tables"]}
        for schema in schemas:
            assert f"GRANT USAGE ON SCHEMA {schema} TO devai_evals" in EVALS_SQL, (
                f"{path.name}: devai_evals lacks USAGE on schema {schema}"
            )
            assert (
                f"GRANT SELECT, INSERT, TRUNCATE ON ALL TABLES IN SCHEMA {schema}"
                in EVALS_SQL
            ), f"{path.name}: devai_evals lacks table grants on schema {schema}"


def test_every_claim_namespace_has_a_mesh_path_to_global() -> None:
    # allow-apps-to-global + the egress-to-global NetworkPolicy both range over
    # appNamespaces; globalIngressExtraNamespaces covers namespaces shipping
    # their own egress policies.
    allowed = set((ISTIO_VALUES.get("appNamespaces") or {}).values())
    allowed |= set(ISTIO_VALUES.get("globalIngressExtraNamespaces") or [])
    for path, claim in _claims():
        namespace = claim["metadata"]["namespace"]
        assert namespace in allowed, (
            f"{path.name}: namespace {namespace} has no mesh path to "
            "global-postgres — add it to istio-config appNamespaces"
        )


def test_evals_snapshot_grants_are_reapplied_on_every_bootstrap_run() -> None:
    application = yaml.safe_load(GLOBAL_SCHEMA_APP.read_text())
    values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
    assert "devai_evals_db" in values["targets"][0]["reapplyExistingSchemas"], (
        "devai_evals_db must be reapplied so new schema grants converge "
        "(CNPG creates the devai_evals role asynchronously)"
    )
