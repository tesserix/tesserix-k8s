from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).parents[1]


def render(chart, *args):
    return [
        d
        for d in yaml.safe_load_all(
            subprocess.check_output(
                ["helm", "template", chart, str(ROOT / "charts/apps" / chart), *args],
                text=True,
            )
        )
        if d
    ]


def assert_openbao(document, development=False):
    store = "openbao-roamie-development" if development else "openbao-roamie-production"
    prefix = "roamie-development/app/roamie-" if development else "roamie/app/roamie-"
    assert document["spec"]["secretStoreRef"] == {"name": store, "kind": "SecretStore"}
    for entry in document["spec"]["data"]:
        if entry["remoteRef"]["key"].startswith("homechef/"):
            assert entry["sourceRef"]["storeRef"]["name"] == "openbao-fe3dr-shared"
        else:
            assert entry["remoteRef"]["key"].startswith(prefix)
        assert entry["remoteRef"]["property"] == "value"
        assert "version" not in entry["remoteRef"]


def test_api_bridge_ai_and_database_read_openbao_without_gcp_fallback():
    documents = (
        render("roamie-api")
        + render("roamie-postgres")
        + render(
            "roamie-ai",
            "-f",
            str(ROOT / "charts/apps/roamie-ai/values-validation.yaml"),
        )
    )
    secrets = [d for d in documents if d["kind"] == "ExternalSecret"]
    assert len(secrets) == 7
    for secret in secrets:
        assert_openbao(secret)


def test_document_intelligence_keeps_development_and_production_separate():
    docs = render(
        "document-intelligence",
        "-f",
        str(ROOT / "charts/apps/document-intelligence/products/roamie-prod.yaml"),
    )
    for secret in [d for d in docs if d["kind"] == "ExternalSecret"]:
        assert_openbao(secret)
    sandbox = render(
        "document-intelligence",
        "-f",
        str(ROOT / "charts/apps/document-intelligence/values-sandbox.yaml"),
    )
    identity = next(
        d
        for d in sandbox
        if d["kind"] == "ExternalSecret"
        and d["metadata"]["name"].endswith("api-identity")
    )
    assert identity["spec"]["secretStoreRef"]["name"] == "openbao-kora-development"
    extra = next(e for e in identity["spec"]["data"] if e["secretKey"] == "extra_0")
    assert extra["sourceRef"]["storeRef"] == {
        "name": "openbao-roamie-development",
        "kind": "SecretStore",
    }
    assert extra["remoteRef"] == {
        "key": "roamie-development/app/roamie-api-ocr-key",
        "property": "value",
    }


def test_shared_gateway_registry_and_database_consumers_use_exact_roamie_paths():
    documents = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    for namespace, name, field, key in [
        (
            "global",
            "global-postgres-document-intelligence-roamie-prod",
            "password",
            "roamie-document-intelligence-db-password",
        ),
        (
            "agentgateway-system",
            "product-mcp-upstream-keys",
            "ROAMIE_TRAVEL_MCP_KEY",
            "roamie-travel-mcp-key",
        ),
    ]:
        secret = next(
            d
            for d in documents
            if d
            and d["kind"] == "ExternalSecret"
            and d["metadata"]["name"] == name
            and d["metadata"]["namespace"] == namespace
        )
        entry = next(e for e in secret["spec"]["data"] if e["secretKey"] == field)
        assert entry["sourceRef"]["storeRef"] == {
            "name": "openbao-roamie-production",
            "kind": "SecretStore",
        }
        assert entry["remoteRef"] == {"key": "roamie/app/" + key, "property": "value"}


def test_api_rollout_annotation_preserves_custom_annotations():
    deployment = next(
        d
        for d in render("roamie-api", "--set-string", "podAnnotations.custom=test")
        if d["kind"] == "Deployment"
    )
    annotations = deployment["spec"]["template"]["metadata"]["annotations"]
    assert annotations["custom"] == "test"
    assert annotations["secrets.tesserix.app/source-revision"] == "roamie-openbao-v1"
