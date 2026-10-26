import subprocess
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
REVISION = "gar-2026-10-19"
MIRROR = "asia-south1-docker.pkg.dev/tesseracthub-480811/"
PG_DIGEST = "sha256:99be063781d171d3971089b49c992706bdab9ccbd2b57cdf126c7542773aedfe"


def production_rows(application):
    app = yaml.safe_load(
        (ROOT / f"argocd/prod/apps/helivanta/{application}.yaml").read_text()
    )
    source = app["spec"]["source"]
    helm = source["helm"]
    values = helm.get("valuesObject") or yaml.safe_load(helm.get("values", "{}"))
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as file:
        yaml.safe_dump(values, file)
        file.flush()
        output = subprocess.check_output(
            [
                "helm",
                "template",
                application,
                str(ROOT / source["path"]),
                "--namespace",
                "helivanta",
                "-f",
                file.name,
            ],
            text=True,
        )
    return [row for row in yaml.safe_load_all(output) if row]


def test_mirror_cutover_replaces_database_reference_without_an_engine_upgrade():
    rows = production_rows("helivanta-postgres")
    cluster = next(r for r in rows if r["kind"] == "Cluster")
    assert cluster["spec"]["instances"] == 2
    assert (
        cluster["spec"]["imageName"]
        == MIRROR + "ghcr-remote/cloudnative-pg/postgresql:16.4@" + PG_DIGEST
    )
    values = yaml.safe_load(
        (ROOT / "charts/apps/helivanta-postgres/values.yaml").read_text()
    )
    assert (
        values["restoreCheck"]["image"]
        == MIRROR + "ghcr-remote/cloudnative-pg/postgresql@" + PG_DIGEST
    )


def test_cutover_recreates_each_injected_workload_with_no_application_surge():
    rows = production_rows("helivanta-api") + production_rows("helivanta-shell")
    deployments = [r for r in rows if r["kind"] == "Deployment"]
    assert {r["metadata"]["name"] for r in deployments} == {
        "helivanta-api",
        "helivanta-shell",
        "helivanta-document-worker",
        "helivanta-supply-evidence-worker",
        "helivanta-emergency-worker",
        "helivanta-privacy-worker",
        "helivanta-clamav",
    }
    for deployment in deployments:
        pod = deployment["spec"]["template"]
        assert (
            pod["metadata"]["annotations"]["tesserix.app/registry-mirror-revision"]
            == REVISION
        )
        assert all(c["image"].startswith(MIRROR) for c in pod["spec"]["containers"])
        if deployment["metadata"]["name"] == "helivanta-clamav":
            assert deployment["spec"]["strategy"]["type"] == "Recreate"
        else:
            assert deployment["spec"]["strategy"]["rollingUpdate"]["maxSurge"] == 0
    api = next(r for r in deployments if r["metadata"]["name"] == "helivanta-api")
    env = {
        e["name"]: e.get("value")
        for e in api["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    assert env["EMERGENCY_DISPATCH_ENABLED"] == "false"
    assert env["EMERGENCY_WORKFLOWS_ENABLED"] == "true"


def test_future_database_bootstrap_jobs_pull_their_client_from_gcp():
    cron = next(
        r
        for r in production_rows("helivanta-db-schema-bootstrap")
        if r["kind"] == "CronJob"
    )
    pod = cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    for c in pod["containers"] + pod.get("initContainers", []):
        assert c["image"].startswith(MIRROR)
        assert "@sha256:" in c["image"]
