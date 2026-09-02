from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/thirdparty/openpanel"


def test_database_bootstrap_runs_after_migrations_and_before_workloads():
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "openpanel",
            str(CHART),
            "--namespace",
            "openpanel",
            "--values",
            str(CHART / "values-prod.yaml"),
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    jobs = {
        document["metadata"]["name"]: document
        for document in yaml.safe_load_all(rendered)
        if document and document.get("kind") == "Job"
    }

    migrate = jobs["openpanel-migrate"]
    bootstrap = jobs["openpanel-project-init"]

    assert migrate["metadata"]["annotations"]["argocd.argoproj.io/hook"] == "PreSync"
    assert migrate["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "-2"
    assert bootstrap["metadata"]["annotations"]["argocd.argoproj.io/hook"] == "PreSync"
    assert bootstrap["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "-1"
    assert "ttlSecondsAfterFinished" not in bootstrap["spec"]
