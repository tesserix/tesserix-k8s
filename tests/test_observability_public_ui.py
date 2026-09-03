from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]


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
