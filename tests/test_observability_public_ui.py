import subprocess
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]


def render(chart: str, release: str) -> list[dict]:
    result = subprocess.run(
        ["helm", "template", release, str(ROOT / chart), "--namespace", "observability"],
        check=True,
        capture_output=True,
        text=True,
    )
    return [item for item in yaml.safe_load_all(result.stdout) if item]


def test_public_observability_ui_has_redundant_upstreams():
    for component in ("obs-api", "obs-ui"):
        values = yaml.safe_load(
            (ROOT / "charts" / "apps" / component / "values.yaml").read_text()
        )

        assert values["replicaCount"] >= 2, (
            f"{component} backs observability.tesserix.app and cannot be scaled to zero"
        )
        assert values["nodeSelector"] == {"workload": "infrastructure"}
        assert values["tolerations"] == []


def test_public_observability_ui_has_active_collection_tiers() -> None:
    agent = next(
        item
        for item in render("charts/thirdparty/otel-agent", "otel-agent")
        if item["kind"] == "DaemonSet"
    )
    assert "nodeSelector" not in agent["spec"]["template"]["spec"]

    cluster = next(
        item
        for item in render("charts/thirdparty/otel-cluster", "otel-cluster")
        if item["kind"] == "Deployment"
    )
    assert cluster["spec"]["replicas"] == 1
    assert cluster["spec"]["template"]["spec"]["nodeSelector"] == {
        "workload": "infrastructure"
    }
