import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL = (
    ROOT / "charts/apps/db-schema-bootstrap/schemas/devai/devai-db/devai_db.sql"
).read_text()
CHART = (ROOT / "charts/apps/db-schema-bootstrap/Chart.yaml").read_text()
TERRAFORM_PROD = (ROOT / "terraform-new/environments/prod/terraform.tfvars").read_text()


def test_eval_schema_has_immutable_user_scoped_dataset_versions_and_suites() -> None:
    assert "CREATE TABLE IF NOT EXISTS eval_datasets" in SQL
    assert "UNIQUE (owner_scope, name)" in SQL
    assert "CREATE TABLE IF NOT EXISTS eval_dataset_versions" in SQL
    assert "UNIQUE (dataset_id, version)" in SQL
    version_sql = SQL[
        SQL.index("CREATE TABLE IF NOT EXISTS eval_dataset_versions") :
        SQL.index("CREATE TABLE IF NOT EXISTS eval_suites")
    ]
    assert re.search(r"description\s+TEXT NOT NULL DEFAULT ''", version_sql)
    assert "UNIQUE (content_hash)" not in SQL
    assert "CREATE TABLE IF NOT EXISTS eval_suites" in SQL
    assert "UNIQUE (owner_scope, name, version)" in SQL
    assert re.search(r"dataset_version_id\s+UUID NOT NULL REFERENCES eval_dataset_versions\(id\)", SQL)


def test_eval_history_is_durable_and_not_cascaded_from_sandbox_lifecycle() -> None:
    assert "CREATE TABLE IF NOT EXISTS eval_runs" in SQL
    assert "CREATE TABLE IF NOT EXISTS eval_case_results" in SQL
    eval_sql = SQL[SQL.index("CREATE TABLE IF NOT EXISTS eval_runs") :]
    assert "sandbox_id" in eval_sql
    assert "REFERENCES sandboxes" not in eval_sql
    assert re.search(r"dataset_version_id\s+UUID REFERENCES eval_dataset_versions\(id\)", eval_sql)
    assert re.search(r"suite_id\s+UUID REFERENCES eval_suites\(id\)", eval_sql)


def test_eval_owner_scope_indexes_and_chart_release_are_present() -> None:
    assert "idx_eval_datasets_owner" in SQL
    assert "idx_eval_suites_owner" in SQL
    assert "idx_eval_runs_owner_sandbox" in SQL

def test_eval_comparisons_pin_configuration_and_owned_run_pairs() -> None:
    eval_runs_sql = SQL[
        SQL.index("CREATE TABLE IF NOT EXISTS eval_runs") :
        SQL.index("CREATE TABLE IF NOT EXISTS eval_case_results")
    ]
    assert re.search(r"configuration\s+JSONB NOT NULL DEFAULT '\{\}'::jsonb", eval_runs_sql)
    assert re.search(r"dataset_ref\s+JSONB", eval_runs_sql)
    assert re.search(r"suite_ref\s+JSONB", eval_runs_sql)
    assert "CREATE TABLE IF NOT EXISTS eval_comparisons" in SQL
    comparisons_sql = SQL[SQL.index("CREATE TABLE IF NOT EXISTS eval_comparisons") :]
    assert re.search(r"owner_scope\s+TEXT NOT NULL", comparisons_sql)
    assert re.search(r"baseline_run_id\s+TEXT NOT NULL REFERENCES eval_runs\(id\)", comparisons_sql)
    assert re.search(r"candidate_run_id\s+TEXT NOT NULL REFERENCES eval_runs\(id\)", comparisons_sql)
    assert "ON DELETE CASCADE" not in comparisons_sql.split("CREATE INDEX", maxsplit=1)[0]
    assert "idx_eval_comparisons_owner" in SQL

def test_eval_blob_bucket_is_private_durable_and_workload_scoped() -> None:
    match = re.search(
        r'\{\n\s+name\s+=\s+"devai-prod-evaluations-in"(?P<body>.*?)\n  \},',
        TERRAFORM_PROD,
        re.DOTALL,
    )
    assert match is not None
    bucket = match.group("body")
    assert 'location                    = "asia-south1"' in bucket
    assert "force_destroy               = false" in bucket
    assert "uniform_bucket_level_access = true" in bucket
    assert 'public_access_prevention    = "enforced"' in bucket
    assert "versioning                  = true" in bucket
    assert 'type = "Delete"' not in bucket
    assert 'role   = "roles/storage.objectUser"' in bucket
    assert (
        'member = "serviceAccount:app-secrets-devai-prod@tesseracthub-480811.iam.gserviceaccount.com"'
        in bucket
    )
