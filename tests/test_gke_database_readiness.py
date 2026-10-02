"""The active single-instance databases need standbys before node drains."""

from pathlib import Path
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
APPLICATIONS = [
    "ai-apps/agentregistry-postgres",
    "ai-apps/devai-postgres",
    "dwellm8/dwellm8-postgres",
    "dwellm8/dwellm8-temporal-postgres",
    "global/global-postgres",
    "helivanta/helivanta-postgres",
    "kora/kora-postgres",
    "ai-apps/postiz-postgres",
    "ai-apps/support-platform-postgres",
    "global/tesserix-postgres",
]


@pytest.mark.parametrize("application", APPLICATIONS)
def test_active_database_has_a_standby(application: str, tmp_path: Path) -> None:
    app = yaml.safe_load(
        (ROOT / "argocd/prod/apps" / f"{application}.yaml").read_text()
    )
    source = app["spec"]["source"]
    chart = ROOT / source["path"]
    helm = source.get("helm", {})
    command = ["helm", "template", app["metadata"]["name"], str(chart)]
    for name in helm.get("valueFiles", []):
        command += ["-f", str(chart / name)]
    for key in ("values", "valuesObject"):
        if key in helm:
            values = tmp_path / f"{key}.yaml"
            values.write_text(
                helm[key] if key == "values" else yaml.safe_dump(helm[key])
            )
            command += ["-f", str(values)]
    result = subprocess.run(command, check=True, text=True, capture_output=True)
    clusters = [
        x for x in yaml.safe_load_all(result.stdout) if x and x.get("kind") == "Cluster"
    ]
    assert len(clusters) == 1
    assert clusters[0]["spec"]["instances"] >= 2
    assert clusters[0]["spec"].get("enablePDB", True) is True
    if application == "global/global-postgres":
        assert clusters[0]["spec"]["affinity"]["podAntiAffinityType"] == "required"
