from pathlib import Path
import subprocess

import yaml


def test_console_api_receives_only_the_recovery_catalog_bucket():
    root = Path(__file__).resolve().parents[1]
    rendered = subprocess.check_output(
        [
            "helm",
            "template",
            "secret-service",
            str(root / "charts/apps/secret-service"),
        ],
        text=True,
    )
    deployment = next(
        doc
        for doc in yaml.safe_load_all(rendered)
        if doc and doc["kind"] == "Deployment"
    )
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    env = {entry["name"]: entry.get("value") for entry in container["env"]}
    assert env["OPENBAO_RECOVERY_BUCKET"] == "tesseracthub-480811-openbao-recovery-prod"
    assert not any("TOKEN" in key and value for key, value in env.items())


def test_openbao_dependency_is_verified_and_available_without_a_download():
    import hashlib

    root = Path(__file__).resolve().parents[1]
    archive = root / "charts/thirdparty/openbao/charts/openbao-0.29.1.tgz"
    assert archive.is_file(), (
        "Recovery reconciliation must work without a release download"
    )
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == (
        "646d932f597632a7328bd300994e66c2cabaa1b6763372cbabb559cd84ff3f2f"
    )
    project = yaml.safe_load((root / "argocd/prod/projects/security.yaml").read_text())
    assert "https://openbao.github.io/openbao-helm" in project["spec"]["sourceRepos"]
