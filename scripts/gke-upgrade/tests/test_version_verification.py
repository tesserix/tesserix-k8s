"""Check actual node versions as well as the GKE pool's target version."""

import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

TARGET = "1.37.0-gke.3503000"
OLD = "1.36.4-gke.1391000"
ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    ("pool_version", "kubelet_version", "expected"),
    [(TARGET, OLD, 1), (OLD, TARGET, 1), (TARGET, TARGET, 0)],
)
def test_selected_pool_requires_matching_pool_and_kubelet_versions(
    tmp_path: Path, pool_version: str, kubelet_version: str, expected: int
) -> None:
    for script in ("verify.sh", "lib.sh"):
        shutil.copy(ROOT / script, tmp_path / script)
    before = tmp_path / "before"
    before.mkdir()
    for kind in ("workloads", "pods", "cnpg", "argocd"):
        (before / f"unhealthy-{kind}.txt").write_text("")
    cluster = {
        "currentMasterVersion": TARGET,
        "nodePools": [
            {"name": "selected", "version": pool_version},
            {"name": "other", "version": OLD},
        ],
    }
    (tmp_path / "cluster.json").write_text(json.dumps(cluster))
    snapshot = tmp_path / "snapshot.sh"
    snapshot.write_text(
        '#!/bin/bash\nset -eu\nmkdir -p "$4"\ncp "$FIXTURE/cluster.json" "$4/cluster.json"\ncp "$FIXTURE/before/"* "$4/"\n'
    )
    snapshot.chmod(0o755)
    nodes = {
        "items": [
            {
                "metadata": {
                    "name": "selected-1",
                    "labels": {"cloud.google.com/gke-nodepool": "selected"},
                },
                "status": {"nodeInfo": {"kubeletVersion": "v" + kubelet_version}},
            },
            {
                "metadata": {
                    "name": "other-1",
                    "labels": {"cloud.google.com/gke-nodepool": "other"},
                },
                "status": {"nodeInfo": {"kubeletVersion": "v" + OLD}},
            },
        ]
    }
    (tmp_path / "nodes.json").write_text(json.dumps(nodes))
    kubectl = tmp_path / "kubectl"
    kubectl.write_text(
        '#!/bin/bash\ncase "$*" in\n "get nodes --no-headers") echo "selected-1 Ready" ;;\n "get nodes -o json") cat "$FIXTURE/nodes.json" ;;\n *) echo \'{"items":[]}\' ;;\nesac\n'
    )
    kubectl.chmod(0o755)
    env = dict(
        os.environ,
        PATH=str(tmp_path) + os.pathsep + os.environ["PATH"],
        FIXTURE=str(tmp_path),
        SETTLE_SECONDS="0",
        EXPECT_NODE_VERSIONS="true",
        ONLY_POOL="selected",
    )
    result = subprocess.run(
        [
            "bash",
            str(tmp_path / "verify.sh"),
            "cluster",
            "region",
            "project",
            TARGET,
            str(before),
            str(tmp_path / "after"),
        ],
        env=env,
        text=True,
        capture_output=True,
    )
    assert result.returncode == expected, result.stdout + result.stderr
    if expected:
        assert "selected" in result.stderr
