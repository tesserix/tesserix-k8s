from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "charts/apps/db-schema-bootstrap/schemas/global/global/onboarding_db.sql"
VALUES = ROOT / "charts/apps/onboarding-service/values.yaml"
DEPLOYMENT = ROOT / "charts/apps/onboarding-service/templates/deployment-api.yaml"


def test_registry_identity_projection_has_no_secret_material():
    sql = SCHEMA.read_text()

    assert "CREATE TABLE IF NOT EXISTS registry_tenants" in sql
    assert "CREATE TABLE IF NOT EXISTS registry_credentials" in sql
    credentials = sql.split("CREATE TABLE IF NOT EXISTS registry_credentials", 1)[1].split(");", 1)[0]
    assert "client_secret" not in credentials
    assert "secret_hash" not in credentials
    assert "verifier" not in credentials
    assert "zitadel_user_id" in credentials
    assert "expires_at" in credentials
    assert "cutover_at" in credentials


def test_onboarding_api_verifies_registry_project_tokens():
    values = VALUES.read_text()
    deployment = DEPLOYMENT.read_text()

    assert 'registryProjectId: "386930054896026901"' in values
    assert "REGISTRY_TOKEN_AUDIENCE" in deployment
    assert "REGISTRY_PROJECT_ID" in deployment
