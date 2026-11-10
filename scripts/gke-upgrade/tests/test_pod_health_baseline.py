"""Track existing Pod failures across worker-driven Pod replacement."""

import json
import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


def snapshot(tmp_path: Path, name: str, pods: list[dict]) -> str:
    fixture = tmp_path / name
    fixture.mkdir()
    (fixture / "pods.json").write_text(json.dumps({"items": pods}))
    for command, body in {
        "gcloud": "echo '{\"nodePools\":[]}'",
        "kubectl": 'if [[ "$*" == "get pods -A -o json" ]]; then cat "$FIXTURE/pods.json"; else echo \'{"items":[]}\'; fi',
    }.items():
        executable = fixture / command
        executable.write_text("#!/bin/bash\n" + body + "\n")
        executable.chmod(0o755)
    output = fixture / "snapshot"
    result = subprocess.run(
        [
            "bash",
            str(ROOT / "snapshot.sh"),
            "cluster",
            "region",
            "project",
            str(output),
        ],
        env={
            **os.environ,
            "PATH": str(fixture) + os.pathsep + os.environ["PATH"],
            "FIXTURE": str(fixture),
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return (output / "unhealthy-pods.txt").read_text()


def pod(name: str, owner: str | None = "api-rs", phase: str = "Pending") -> dict:
    metadata = {"namespace": "app", "name": name}
    if owner:
        metadata["ownerReferences"] = [
            {"kind": "ReplicaSet", "name": owner, "controller": True}
        ]
    return {"metadata": metadata, "status": {"phase": phase}}


def test_replacement_of_existing_unhealthy_pod_keeps_baseline(tmp_path: Path) -> None:
    before = snapshot(tmp_path, "before", [pod("api-old")])
    after = snapshot(tmp_path, "after", [pod("api-new")])
    assert before == after


@pytest.mark.parametrize(
    "change", ["extra-unhealthy-replica", "other-controller", "other-phase"]
)
def test_new_or_worsened_pod_failure_changes_baseline(
    tmp_path: Path, change: str
) -> None:
    before = snapshot(tmp_path, "before", [pod("api-old")])
    after_pods = [pod("api-new")]
    if change == "extra-unhealthy-replica":
        after_pods.append(pod("api-extra"))
    elif change == "other-controller":
        after_pods = [pod("other-new", owner="other-rs")]
    else:
        after_pods = [pod("api-new", phase="Failed")]
    assert snapshot(tmp_path, "after", after_pods) != before


def test_standalone_unhealthy_pods_keep_their_identity(tmp_path: Path) -> None:
    assert snapshot(tmp_path, "before", [pod("one", owner=None)]) != snapshot(
        tmp_path, "after", [pod("two", owner=None)]
    )
