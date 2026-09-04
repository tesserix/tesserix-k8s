import subprocess
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/apps/document-intelligence"


def render(environment: str) -> list[dict]:
    output = subprocess.run(
        [
            "helm",
            "template",
            "document-intelligence",
            str(CHART),
            "--namespace",
            "document-intelligence",
            "--values",
            str(CHART / f"values-{environment}.yaml"),
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [resource for resource in yaml.safe_load_all(output) if resource]


def deployment(resources: list[dict], name: str) -> dict:
    return next(
        resource
        for resource in resources
        if resource["kind"] == "Deployment" and resource["metadata"]["name"] == name
    )


def environment(deployment: dict) -> dict[str, str]:
    return {
        item["name"]: item["value"]
        for item in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        if "value" in item
    }


def test_runtime_separates_upload_job_and_worker_privileges() -> None:
    resources = render("prod")
    names = {
        resource["metadata"]["name"]
        for resource in resources
        if resource["kind"] == "Deployment"
    }
    assert names == {
        "document-intelligence-prod-upload-api",
        "document-intelligence-prod-job-api",
        "document-intelligence-prod-dispatch-worker",
        "document-intelligence-prod-execution-worker",
    }

    upload = deployment(resources, "document-intelligence-prod-upload-api")
    jobs = deployment(resources, "document-intelligence-prod-job-api")
    dispatch = deployment(resources, "document-intelligence-prod-dispatch-worker")
    execution = deployment(resources, "document-intelligence-prod-execution-worker")

    assert upload["spec"]["template"]["spec"]["serviceAccountName"] == "kora-doc-signer"
    assert jobs["spec"]["template"]["spec"]["serviceAccountName"] == "kora-doc-result-api"
    assert dispatch["spec"]["template"]["spec"]["serviceAccountName"] == "kora-doc-scanner"
    assert execution["spec"]["template"]["spec"]["serviceAccountName"] == "kora-doc-worker"
    assert environment(upload)["OCR_API_CAPABILITY"] == "uploads"
    assert environment(jobs)["OCR_API_CAPABILITY"] == "jobs"
    assert "RESULT_BUCKETS" not in environment(upload)
    assert "QUARANTINE_BUCKETS" not in environment(jobs)
    assert environment(dispatch)["CLAMD_ADDRESS"] == "127.0.0.1:3310"
    assert environment(execution)["TEMPORAL_NAMESPACE"] == "document-intelligence-prod"


def test_sandbox_uses_dev_credentials_and_ephemeral_document_buckets() -> None:
    resources = render("sandbox")
    upload = deployment(resources, "document-intelligence-sandbox-upload-api")
    jobs = deployment(resources, "document-intelligence-sandbox-job-api")
    dispatch = deployment(resources, "document-intelligence-sandbox-dispatch-worker")
    execution = deployment(resources, "document-intelligence-sandbox-execution-worker")

    assert upload["spec"]["template"]["spec"]["serviceAccountName"] == "kora-dev-doc-signer"
    assert jobs["spec"]["template"]["spec"]["serviceAccountName"] == "kora-dev-doc-result-api"
    assert dispatch["spec"]["template"]["spec"]["serviceAccountName"] == "kora-dev-doc-scanner"
    assert execution["spec"]["template"]["spec"]["serviceAccountName"] == "kora-dev-doc-worker"
    assert environment(execution)["TEMPORAL_NAMESPACE"] == "document-intelligence-sandbox"
    assert environment(upload)["QUARANTINE_BUCKETS"] == "kora=kora-dev-doc-quarantine-in"
    assert environment(execution)["RESULT_BUCKETS"] == "kora=kora-dev-doc-results-in"


def test_runtime_remains_internal_hardened_and_secret_free() -> None:
    resources = render("prod")
    assert not any(
        resource["kind"] in {"Ingress", "Gateway", "HTTPRoute"} for resource in resources
    )
    assert all(
        resource["spec"].get("type", "ClusterIP") == "ClusterIP"
        for resource in resources
        if resource["kind"] == "Service"
    )
    policies = [resource for resource in resources if resource["kind"] == "NetworkPolicy"]
    assert policies
    assert not any(resource["kind"] == "Secret" for resource in resources)
    for resource in resources:
        if resource["kind"] != "Deployment":
            continue
        for container in resource["spec"]["template"]["spec"]["containers"]:
            for item in container.get("env", []):
                if item["name"] in {"DATABASE_URL", "OCR_WORKLOAD_IDENTITY_KEYS"}:
                    assert "value" not in item
                    assert "valueFrom" in item
