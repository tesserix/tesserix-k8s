import pathlib
import subprocess

import yaml


ROOT = pathlib.Path(__file__).parents[1]


def test_mark8ly_waypoint_exists_before_ambient_enrollment() -> None:
    result = subprocess.run(
        [
            "helm",
            "template",
            "istio-config",
            str(ROOT / "charts/thirdparty/istio-config"),
            "--namespace",
            "istio-system",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    documents = [document for document in yaml.safe_load_all(result.stdout) if document]
    waypoints = [
        document
        for document in documents
        if document.get("kind") == "Gateway"
        and document.get("metadata", {}).get("name") == "waypoint"
        and document.get("metadata", {}).get("namespace") == "mark8ly"
    ]

    assert len(waypoints) == 1
