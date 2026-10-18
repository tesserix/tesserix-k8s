"""Emergency intake contact maintenance stays bounded and inactive until promotion."""

import pathlib
import subprocess

import yaml

ROOT = pathlib.Path(__file__).parents[1]


def render(*settings):
    args = [arg for setting in settings for arg in ("--set", setting)]
    result = subprocess.run(
        [
            "helm",
            "template",
            "release",
            str(ROOT / "charts/apps/helivanta-api"),
            "--namespace",
            "helivanta",
            *args,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def test_default_release_does_not_activate_contact_maintenance():
    assert not any(doc["kind"] == "CronJob" for doc in render())


def test_retention_is_suspended_bounded_and_uses_promoted_gar_image():
    docs = render("emergencyRetention.enabled=true")
    cron = next(doc for doc in docs if doc["kind"] == "CronJob")
    assert cron["spec"]["suspend"] is True
    assert cron["spec"]["concurrencyPolicy"] == "Forbid"
    assert cron["spec"]["schedule"] == "*/15 * * * *"
    job = cron["spec"]["jobTemplate"]["spec"]
    assert job["activeDeadlineSeconds"] == 330
    assert job["backoffLimit"] == 1
    pod = job["template"]["spec"]
    service = next(doc for doc in docs if doc["kind"] == "Service")
    labels = job["template"]["metadata"]["labels"]
    assert not all(
        labels.get(key) == value for key, value in service["spec"]["selector"].items()
    )
    assert pod["automountServiceAccountToken"] is False
    assert (
        job["template"]["metadata"]["annotations"]["sidecar.istio.io/inject"] == "false"
    )
    container = pod["containers"][0]
    deployment = next(
        doc
        for doc in docs
        if doc["kind"] == "Deployment" and doc["metadata"]["name"] == "helivanta-api"
    )
    assert (
        container["image"]
        == deployment["spec"]["template"]["spec"]["containers"][0]["image"]
    )
    assert container["image"].startswith("asia-south1-docker.pkg.dev/")
    assert container["command"] == ["/app/emergency-retention"]
    assert container["args"] == ["-batch-size=200", "-max-batches=10"]
    env = {item["name"]: item for item in container["env"]}
    assert "ADMIN_DATABASE_URL" not in env
    assert "OPENBAO_ADDR" not in env
    assert (
        env["APP_DB_USER"]["valueFrom"]["secretKeyRef"]["name"]
        == "helivanta-postgres-api-credentials"
    )
    assert (
        env["SYSTEM_DB_USER"]["valueFrom"]["secretKeyRef"]["name"]
        == "helivanta-postgres-system-credentials"
    )
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    assert container["resources"]["requests"]["memory"] == "64Mi"


def test_retention_cannot_be_unsuspended_without_explicit_release_setting():
    docs = render("emergencyRetention.enabled=true", "emergencyRetention.suspend=false")
    assert (
        next(doc for doc in docs if doc["kind"] == "CronJob")["spec"]["suspend"]
        is False
    )


def test_enabled_retention_has_an_unsuspended_missing_success_alert():
    docs = render("emergencyRetention.enabled=true")
    rule = next(
        doc
        for doc in docs
        if doc["kind"] == "PrometheusRule"
        and doc["metadata"]["name"] == "helivanta-emergency-retention"
    )
    alert = rule["spec"]["groups"][0]["rules"][0]
    assert alert["alert"] == "HelivantaEmergencyContactRetentionOverdue"
    assert alert["labels"] == {"severity": "warning", "owner": "helivanta"}
    assert "kube_cronjob_spec_suspend" in alert["expr"]
    assert "kube_cronjob_status_last_successful_time" in alert["expr"]
    assert "unless" in alert["expr"]
    assert "3600" in alert["expr"]
    assert alert["annotations"]["runbook_url"].endswith(
        "helivanta-emergency-retention.md"
    )
