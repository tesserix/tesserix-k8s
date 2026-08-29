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


def test_agent_imports_are_immutable_tenant_scoped_and_idempotent() -> None:
    assert "CREATE TABLE IF NOT EXISTS agent_imports" in SQL
    imports_sql = SQL[
        SQL.index("CREATE TABLE IF NOT EXISTS agent_imports") :
        SQL.index("CREATE TABLE IF NOT EXISTS eval_datasets")
    ]
    assert re.search(r"owner_scope\s+TEXT NOT NULL", imports_sql)
    assert re.search(r"project_id\s+TEXT NOT NULL", imports_sql)
    assert re.search(r"registry_ref\s+TEXT NOT NULL", imports_sql)
    assert re.search(r"agent\s+JSONB NOT NULL", imports_sql)
    assert re.search(r"dependency_lock\s+JSONB NOT NULL", imports_sql)
    assert "UNIQUE (owner_scope, project_id, idempotency_key)" in imports_sql
    assert "CHECK (state IN ('ready', 'blocked', 'failed', 'pending_verification'))" in imports_sql
    assert "idx_agent_imports_owner_project_created" in SQL


def test_agent_import_creation_has_a_transactional_outbox() -> None:
    assert "CREATE TABLE IF NOT EXISTS agent_import_outbox" in SQL
    outbox_sql = SQL[
        SQL.index("CREATE TABLE IF NOT EXISTS agent_import_outbox") :
        SQL.index("CREATE TABLE IF NOT EXISTS eval_datasets")
    ]
    assert re.search(r"import_id\s+UUID NOT NULL REFERENCES agent_imports\(id\)", outbox_sql)
    assert re.search(r"owner_scope\s+TEXT NOT NULL", outbox_sql)
    assert re.search(r"published_at\s+TIMESTAMPTZ", outbox_sql)
    assert "idx_agent_import_outbox_unpublished" in SQL


def test_agent_lifecycle_transitions_have_an_append_only_transactional_outbox() -> None:
    assert "CREATE TABLE IF NOT EXISTS agent_lifecycle_events" in SQL
    events_sql = SQL[
        SQL.index("CREATE TABLE IF NOT EXISTS agent_lifecycle_events") :
        SQL.index("CREATE TABLE IF NOT EXISTS agent_lifecycle_outbox")
    ]
    assert "UNIQUE (workflow_id, sequence)" in events_sql
    assert re.search(r"owner_scope\s+TEXT NOT NULL", events_sql)
    assert re.search(r"operation\s+TEXT NOT NULL", events_sql)
    assert re.search(r"state\s+TEXT NOT NULL", events_sql)
    assert "CREATE TABLE IF NOT EXISTS agent_lifecycle_outbox" in SQL
    outbox_sql = SQL[
        SQL.index("CREATE TABLE IF NOT EXISTS agent_lifecycle_outbox") :
        SQL.index("CREATE TABLE IF NOT EXISTS eval_datasets")
    ]
    assert re.search(r"event_id\s+UUID NOT NULL REFERENCES agent_lifecycle_events\(id\)", outbox_sql)
    assert "UNIQUE (event_id, event_type)" in outbox_sql
    assert "idx_agent_lifecycle_outbox_unpublished" in outbox_sql

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
