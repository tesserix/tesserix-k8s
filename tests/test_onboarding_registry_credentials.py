from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "charts/apps/db-schema-bootstrap/schemas/global/global/onboarding_db.sql"
VALUES = ROOT / "charts/apps/onboarding-service/values.yaml"
DEPLOYMENT = ROOT / "charts/apps/onboarding-service/templates/deployment-api.yaml"
GLOBAL_SCHEMA_APP = ROOT / "argocd/prod/apps/global/global-db-schema-bootstrap.yaml"


def render_chart(chart: str, release: str, namespace: str):
    rendered = subprocess.run(
        ["helm", "template", release, str(ROOT / chart), "--namespace", namespace],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [document for document in yaml.safe_load_all(rendered) if document]


def resource(documents, kind: str, name: str):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


def test_registry_identity_projection_has_no_secret_material():
    sql = SCHEMA.read_text()

    assert "SET lock_timeout = '5s'" in sql
    assert "SET statement_timeout = '2min'" in sql
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


def test_registry_can_reach_the_onboarding_identity_control_plane():
    documents = render_chart(
        "charts/thirdparty/istio-config", "istio-config", "istio-system"
    )
    policy = resource(documents, "NetworkPolicy", "allow-agentregistry-egress")
    destination_namespaces = {
        peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
        for rule in policy["spec"]["egress"]
        for peer in rule.get("to", [])
        if "namespaceSelector" in peer
        and "kubernetes.io/metadata.name"
        in peer["namespaceSelector"].get("matchLabels", {})
    }

    assert "onboarding" in destination_namespaces


def test_existing_onboarding_database_receives_idempotent_schema_updates(tmp_path):
    application = yaml.safe_load(GLOBAL_SCHEMA_APP.read_text())
    values_text = application["spec"]["source"]["helm"]["values"]
    values = yaml.safe_load(values_text)
    target = values["targets"][0]

    assert "onboarding_db" in target["reapplyExistingSchemas"]

    values_file = tmp_path / "values.yaml"
    values_file.write_text(values_text)
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "global-db-schema-bootstrap",
            str(ROOT / "charts/apps/db-schema-bootstrap"),
            "--namespace",
            "global",
            "--values",
            str(values_file),
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    documents = [document for document in yaml.safe_load_all(rendered) if document]
    scripts = resource(
        documents, "ConfigMap", "global-db-schema-bootstrap-scripts"
    )["data"]["bootstrap.sh"]

    assert "REAPPLY_EXISTING=false" in scripts
    assert '"onboarding_db") REAPPLY_EXISTING=true ;;' in scripts
    assert '&& [ "$REAPPLY_EXISTING" != "true" ]' in scripts
