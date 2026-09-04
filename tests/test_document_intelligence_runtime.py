import subprocess
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/apps/document-intelligence"
ISTIO_CONFIG_VALUES = ROOT / "charts/thirdparty/istio-config/values.yaml"


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


def test_clamd_has_a_writable_runtime_directory_with_a_read_only_root() -> None:
    dispatch = deployment(render("sandbox"), "document-intelligence-sandbox-dispatch-worker")
    init = next(
        container
        for container in dispatch["spec"]["template"]["spec"]["initContainers"]
        if container["name"] == "clamd-volume-owner"
    )
    clamd = next(
        container
        for container in dispatch["spec"]["template"]["spec"]["containers"]
        if container["name"] == "clamd"
    )

    assert clamd["securityContext"]["readOnlyRootFilesystem"] is True
    assert clamd["securityContext"]["runAsUser"] == 0
    assert clamd["securityContext"]["runAsNonRoot"] is False
    assert clamd["securityContext"]["capabilities"] == {
        "add": ["CHOWN", "DAC_OVERRIDE", "SETGID", "SETUID"],
        "drop": ["ALL"],
    }
    assert dispatch["spec"]["template"]["spec"]["securityContext"]["fsGroup"] == 10001
    assert {mount["mountPath"] for mount in clamd["volumeMounts"]} >= {
        "/run/clamav",
        "/run/lock",
        "/var/lib/clamav",
        "/var/log/clamav",
    }
    mounts = {mount["mountPath"]: mount["name"] for mount in clamd["volumeMounts"]}
    assert mounts["/var/lib/clamav"] == "clamd-data"
    assert mounts["/var/log/clamav"] == "clamd-logs"
    init_mounts = {mount["mountPath"]: mount["name"] for mount in init["volumeMounts"]}
    assert init_mounts["/var/log/clamav"] == "clamd-logs"
    assert "/var/log/clamav" in init["command"][2]


def test_runtime_allows_only_required_dns_and_workload_identity_egress() -> None:
    resources = render("sandbox")
    policy = next(resource for resource in resources if resource["kind"] == "NetworkPolicy")
    egress = policy["spec"]["egress"]

    assert any(
        rule.get("to") == [{"ipBlock": {"cidr": "10.30.0.10/32"}}]
        and {port["port"] for port in rule["ports"]} == {53}
        for rule in egress
    )
    assert any(
        {target["ipBlock"]["cidr"] for target in rule.get("to", []) if "ipBlock" in target}
        == {"169.254.169.254/32"}
        and {port["port"] for port in rule["ports"]} == {80}
        for rule in egress
    )
    assert any(
        rule.get("to") == [{"ipBlock": {"cidr": "169.254.169.252/32"}}]
        and {port["port"] for port in rule["ports"]} == {988}
        for rule in egress
    )
    assert any(
        rule.get("to") == [{"ipBlock": {"cidr": "10.20.0.0/16"}}]
        and {port["port"] for port in rule["ports"]} == {15008}
        for rule in egress
    )

    for name in {
        "document-intelligence-sandbox-upload-api",
        "document-intelligence-sandbox-job-api",
        "document-intelligence-sandbox-dispatch-worker",
        "document-intelligence-sandbox-execution-worker",
    }:
        annotations = deployment(resources, name)["spec"]["template"]["metadata"]["annotations"]
        assert annotations["traffic.istio.io/excludeOutboundIPRanges"] == (
            "169.254.169.254/32,169.254.169.252/32"
        )


def test_global_cnpg_ingress_explicitly_allows_document_intelligence() -> None:
    values = yaml.safe_load(ISTIO_CONFIG_VALUES.read_text())

    assert "document-intelligence" in values["globalIngressExtraNamespaces"]
