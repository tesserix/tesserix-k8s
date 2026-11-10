"""A long-running cloud operation must not cause duplicate node upgrades."""

import json
import os
from pathlib import Path
import subprocess

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "upgrade.sh"
TARGET = "1.37.2-gke.1042000"
OLD = "1.37.1-gke.1697000"


def run_upgrade(
    tmp_path: Path, mode: str, pool_version: str = OLD, kubelet: str = OLD
) -> subprocess.CompletedProcess[str]:
    binaries = tmp_path / "bin"
    binaries.mkdir()
    (tmp_path / "nodes.json").write_text(
        json.dumps(
            {"items": [{"status": {"nodeInfo": {"kubeletVersion": "v" + kubelet}}}]}
        )
    )
    gcloud = binaries / "gcloud"
    gcloud.write_text("""#!/bin/bash
set -eu
case "$*" in
 *'--format=value(nodePools[].name)'*) echo workers ;;
 *'node-pools describe'*) echo "$POOL_VERSION" ;;
 *'clusters upgrade'*) echo "$*" >> "$FIXTURE/upgrades"; echo operation-test-123 ;;
 *'operations describe'*)
  n=0; [ ! -f "$FIXTURE/polls" ] || n=$(cat "$FIXTURE/polls")
  n=$((n+1)); echo "$n" > "$FIXTURE/polls"
  case "$MODE" in
   failed) echo '{"status":"DONE","error":{"code":9,"message":"provider rejected upgrade"}}' ;;
   forever) echo '{"status":"RUNNING"}' ;;
   malformed) echo '{}' ;;
   *) if [ "$n" -lt 3 ]; then echo '{"status":"RUNNING"}'; else echo '{"status":"DONE"}'; fi ;;
  esac ;;
 *) exit 2 ;;
esac
""")
    gcloud.chmod(0o755)
    kubectl = binaries / "kubectl"
    kubectl.write_text('#!/bin/bash\ncat "$FIXTURE/nodes.json"\n')
    kubectl.chmod(0o755)
    return subprocess.run(
        [
            "bash",
            str(SCRIPT),
            "cluster",
            "asia-south1",
            "project",
            TARGET,
            "node-pools",
            str(tmp_path),
        ],
        env={
            **os.environ,
            "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
            "FIXTURE": str(tmp_path),
            "MODE": mode,
            "POOL_VERSION": pool_version,
            "DRY_RUN": "false",
            "OPERATION_MAX_POLLS": "3",
            "OPERATION_POLL_SECONDS": "0",
        },
        capture_output=True,
        text=True,
    )


def test_starts_one_async_upgrade_and_waits_for_its_completion(tmp_path: Path) -> None:
    result = run_upgrade(tmp_path, "success")
    assert result.returncode == 0, result.stdout + result.stderr
    calls = (tmp_path / "upgrades").read_text().splitlines()
    assert len(calls) == 1
    assert "--async" in calls[0]
    assert (tmp_path / "polls").read_text().strip() == "3"


def test_completed_pool_and_kubelets_are_not_upgraded_again(tmp_path: Path) -> None:
    result = run_upgrade(tmp_path, "success", TARGET, TARGET)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (tmp_path / "upgrades").exists()


def test_pool_target_alone_does_not_hide_old_kubelets(tmp_path: Path) -> None:
    result = run_upgrade(tmp_path, "success", TARGET, OLD)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "--async" in (tmp_path / "upgrades").read_text()
    assert (tmp_path / "polls").read_text().strip() == "3"


@pytest.mark.parametrize("mode", ["failed", "forever", "malformed"])
def test_failure_or_wait_limit_does_not_reissue_upgrade(
    tmp_path: Path, mode: str
) -> None:
    result = run_upgrade(tmp_path, mode)
    assert result.returncode != 0
    assert len((tmp_path / "upgrades").read_text().splitlines()) == 1
    if mode == "forever":
        assert "operation-test-123" in result.stderr
        assert "still running" in result.stderr
