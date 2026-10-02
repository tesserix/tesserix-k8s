import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("haproxy", ["true", "false"])
def test_each_valkey_workload_matches_exactly_one_budget(haproxy):
    rendered = subprocess.check_output(
        [
            "helm",
            "template",
            "test",
            str(ROOT / "charts/apps/global-valkey"),
            "--set",
            f"haproxy.enabled={haproxy}",
        ],
        text=True,
    )
    objects = [obj for obj in yaml.safe_load_all(rendered) if obj]
    budgets = [obj for obj in objects if obj["kind"] == "PodDisruptionBudget"]
    for workload in objects:
        if workload["kind"] not in ("StatefulSet", "Deployment"):
            continue
        labels = workload["spec"]["template"]["metadata"]["labels"]
        matching = []
        for budget in budgets:
            selector = budget["spec"]["selector"]
            if not all(
                labels.get(k) == v for k, v in selector.get("matchLabels", {}).items()
            ):
                continue
            if any(
                e["operator"] == "NotIn" and labels.get(e["key"]) in e["values"]
                for e in selector.get("matchExpressions", [])
            ):
                continue
            matching.append(budget["metadata"]["name"])
        assert len(matching) == 1, (workload["metadata"]["name"], matching)
