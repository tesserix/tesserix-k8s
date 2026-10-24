import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart, *values, overrides=()):
    command = [
        "helm",
        "template",
        "park-test",
        str(ROOT / chart),
        "--namespace",
        "homechef",
    ]
    for value in values:
        command.extend(["-f", str(ROOT / chart / value)])
    for override in overrides:
        command.extend(["--set", override])
    return [
        doc
        for doc in yaml.safe_load_all(subprocess.check_output(command, text=True))
        if doc
    ]


def test_postgres_hibernates_without_removing_database_or_poolers():
    docs = render("charts/apps/homechef-postgres")
    cluster = next(doc for doc in docs if doc["kind"] == "Cluster")
    assert cluster["metadata"]["annotations"]["cnpg.io/hibernation"] == "on"
    assert cluster["spec"]["instances"] == 2
    assert cluster["spec"]["storage"]["size"] == "100Gi"
    poolers = [doc for doc in docs if doc["kind"] == "Pooler"]
    assert len(poolers) == 2
    assert all(doc["spec"]["instances"] == 0 for doc in poolers)
    jobs = [doc for doc in docs if doc["kind"] in ("CronJob", "ScheduledBackup")]
    assert len(jobs) == 2
    assert all(doc["spec"]["suspend"] for doc in jobs)


def test_postgres_can_resume_with_existing_storage():
    docs = render("charts/apps/homechef-postgres", overrides=("hibernate=false",))
    cluster = next(doc for doc in docs if doc["kind"] == "Cluster")
    assert (
        cluster["metadata"].get("annotations", {}).get("cnpg.io/hibernation", "off")
        == "off"
    )
    assert all(doc["spec"]["instances"] == 2 for doc in docs if doc["kind"] == "Pooler")


@pytest.mark.parametrize(
    "chart,values",
    [
        ("charts/apps/homechef-api", ("values-prod.yaml",)),
        ("charts/apps/homechef-web", ("values-prod.yaml",)),
        ("charts/apps/homechef-web-app", ("values-prod.yaml",)),
        ("charts/apps/homechef-vendor-portal", ("values-prod.yaml",)),
        ("charts/apps/homechef-auth-bff", ()),
        ("charts/apps/temporal", ("values-homechef.yaml",)),
        ("charts/infrastructure/cloudflared", ("values-homechef.yaml",)),
        ("charts/apps/document-intelligence", ("products/homechef-prod.yaml",)),
    ],
)
def test_dedicated_workloads_stay_at_zero_without_autoscalers(chart, values):
    docs = render(chart, *values)
    deployments = [doc for doc in docs if doc["kind"] == "Deployment"]
    assert deployments
    assert all(doc["spec"].get("replicas") == 0 for doc in deployments)
    assert not any(
        doc["kind"] in ("HorizontalPodAutoscaler", "ScaledObject") for doc in docs
    )
    assert not any(doc["kind"] == "Job" for doc in docs)


def test_other_ocr_products_keep_running():
    docs = render("charts/apps/document-intelligence", "products/roamie-prod.yaml")
    deployments = [doc for doc in docs if doc["kind"] == "Deployment"]
    assert len(deployments) == 4
    assert all(doc["spec"]["replicas"] > 0 for doc in deployments)


def test_homechef_waypoint_is_parked_without_changing_other_namespaces():
    docs = render("charts/thirdparty/istio-config", "values-prod.yaml")
    gateway = next(
        doc
        for doc in docs
        if doc["kind"] == "Gateway"
        and doc["metadata"].get("namespace") == "homechef"
        and doc["metadata"]["name"] == "waypoint"
    )
    reference = gateway["spec"]["infrastructure"]["parametersRef"]["name"]
    config = next(
        doc
        for doc in docs
        if doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == reference
    )
    assert yaml.safe_load(config["data"]["deployment"])["spec"]["replicas"] == 0
    for doc in docs:
        if doc["kind"] == "Gateway" and doc["metadata"].get("namespace") != "homechef":
            assert "parametersRef" not in doc["spec"].get("infrastructure", {})
