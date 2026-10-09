"""The active single-instance databases need standbys before node drains."""

from pathlib import Path
import json
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
    if application in {"global/global-postgres", "dwellm8/dwellm8-temporal-postgres"}:
        assert clusters[0]["spec"]["affinity"]["podAntiAffinityType"] == "required"


@pytest.mark.parametrize("affinity,ignored", [
    ({"podAntiAffinityType": "preferred"}, True),
    ({"enablePodAntiAffinity": True, "podAntiAffinityType": "preferred", "topologyKey": "kubernetes.io/hostname"}, True),
    ({"podAntiAffinityType": "required"}, False),
    ({"enablePodAntiAffinity": False}, False),
    ({"topologyKey": "topology.kubernetes.io/zone"}, False),
    ({"nodeSelector": {"dedicated": "database"}}, False),
])
def test_argocd_ignores_only_default_database_affinity(affinity, ignored):
    operator = yaml.safe_load((ROOT / "charts/argocd-operator/argocd-instance.yaml").read_text())
    config = yaml.safe_load(operator["spec"]["extraConfig"]["resource.customizations.ignoreDifferences.postgresql.cnpg.io_Cluster"])
    assert "/spec/affinity" not in config.get("jsonPointers", [])
    expressions = [e for e in config.get("jqPathExpressions", []) if ".spec.affinity" in e]
    assert len(expressions) == 4
    normalized = subprocess.run(["jq", "-c", " | ".join("del(" + e + ")" for e in expressions)], input=json.dumps({"spec": {"affinity": affinity}}), text=True, capture_output=True, check=True)
    spec = json.loads(normalized.stdout)["spec"]
    assert ("affinity" not in spec) == ignored
    if not ignored:
        assert spec["affinity"] == affinity
