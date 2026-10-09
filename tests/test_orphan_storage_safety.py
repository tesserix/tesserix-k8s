import datetime as dt
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "storage_audit", ROOT / "scripts/audit-orphan-storage.py"
)
audit = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = audit
SPEC.loader.exec_module(audit)
DISK = "pvc-11111111-1111-1111-1111-111111111111"


def inventory(age=10, attached=False, pvc=False):
    disk = {"name": DISK, "id": "123", "sizeGb": "10", "zone": "zones/asia-south1-b"}
    if age is not None:
        disk["lastDetachTimestamp"] = (audit.NOW - dt.timedelta(days=age)).isoformat()
    if attached:
        disk["users"] = ["instances/node"]
    inv = audit.Inventory(disks=[disk])
    if pvc:
        inv.pv_by_disk[DISK] = DISK
        inv.pvs[DISK] = {
            "metadata": {"name": DISK, "uid": "pv-uid"},
            "status": {"phase": "Released"},
            "spec": {
                "claimRef": {"namespace": "app", "name": "data"},
                "csi": {
                    "driver": "pd.csi.storage.gke.io",
                    "volumeHandle": f"projects/project/zones/asia-south1-b/disks/{DISK}",
                },
            },
        }
        inv.pvcs[("app", "data")] = {"metadata": {"name": "data"}}
    return inv


@pytest.mark.parametrize(
    "age,attached,expected",
    [
        (None, False, False),
        (1, False, False),
        (7, False, True),
        (10, False, True),
        (10, True, False),
    ],
)
def test_deletion_requires_known_old_detach_and_no_attachment(age, attached, expected):
    assert audit.classify(inventory(age, attached), 7)[0].safe_to_delete is expected


def test_released_pv_with_existing_claim_is_protected():
    assert not audit.classify(inventory(pvc=True), 7)[0].safe_to_delete


def test_non_gce_released_pv_is_not_assumed_to_have_missing_disk():
    inv = audit.Inventory(
        pvs={
            "nfs": {
                "metadata": {"name": "nfs"},
                "status": {"phase": "Released"},
                "spec": {"nfs": {"path": "/data"}},
            }
        }
    )
    assert not any(f.safe_to_delete for f in audit.classify(inv, 7))


def test_apply_rechecks_disk_claimed_since_audit(monkeypatch, tmp_path):
    findings = audit.classify(inventory(), 7)
    monkeypatch.setattr(audit, "build_inventory", lambda project: inventory(pvc=True))
    calls = []
    monkeypatch.setattr(audit.subprocess, "run", lambda *a, **kw: calls.append(a))
    actions = audit.apply_safe_deletes(findings, "project", 7, tmp_path)
    assert not calls
    assert any("SKIP" in a for a in actions)


def test_apply_captures_recovery_metadata_before_deletion(monkeypatch, tmp_path):
    inv = inventory()
    monkeypatch.setattr(audit, "build_inventory", lambda project: inv)
    calls = []

    def execute(cmd, **kwargs):
        captures = list(tmp_path.glob("*.json"))
        assert captures, "deletion must follow durable recovery capture"
        assert json.loads(captures[0].read_text())["disk"]["id"] == "123"
        assert captures[0].stat().st_mode & 0o777 == 0o600
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(audit.subprocess, "run", execute)
    actions = audit.apply_safe_deletes(audit.classify(inv, 7), "project", 7, tmp_path)
    assert calls[0][:4] == ["gcloud", "compute", "disks", "delete"]
    assert any("OK" in a for a in actions)


@pytest.mark.parametrize(
    "rc,report,expected", [(0, True, 0), (1, True, 0), (2, True, 2), (1, False, 2)]
)
def test_workflow_reports_findings_but_fails_execution_errors(
    tmp_path, rc, report, expected
):
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/audit-orphan-storage.yml").read_text()
    )
    step = next(
        s for s in workflow["jobs"]["audit"]["steps"] if s.get("id") == "audit_report"
    )
    script = step["run"].replace("${{ steps.inputs.outputs.age }}", "7")
    fake = tmp_path / "bin"
    fake.mkdir()
    python = fake / "python3"
    python.write_text(
        "#!/bin/sh\n"
        + ("echo report > audit-report.md\n" if report else "")
        + f"exit {rc}\n"
    )
    python.chmod(0o700)
    import os

    result = subprocess.run(
        ["bash", "-e", "-c", script],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": f"{fake}:{os.environ['PATH']}",
            "GITHUB_OUTPUT": str(tmp_path / "outputs"),
            "GCP_PROJECT_ID": "project",
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode == expected, result.stdout + result.stderr


def test_failed_pv_delete_does_not_delete_disk(monkeypatch, tmp_path):
    inv = inventory(pvc=True)
    inv.pvcs.clear()
    monkeypatch.setattr(audit, "build_inventory", lambda project: inv)
    calls = []

    def execute(cmd, **kwargs):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 1, "", "denied")

    monkeypatch.setattr(audit.subprocess, "run", execute)
    actions = audit.apply_safe_deletes(audit.classify(inv, 7), "project", 7, tmp_path)
    assert len(calls) == 1
    assert calls[0][:3] == ["kubectl", "delete", "pv"]
    assert any(a.startswith("FAIL:") for a in actions)


def test_main_returns_execution_error_when_delete_fails(monkeypatch, tmp_path):
    monkeypatch.setattr(audit, "build_inventory", lambda project: inventory())
    monkeypatch.setattr(
        audit, "apply_safe_deletes", lambda *args: ["FAIL: disk delete — denied"]
    )
    report = tmp_path / "report.md"
    monkeypatch.setattr(
        sys, "argv", ["audit", "--project", "project", "--apply", "--out", str(report)]
    )
    assert audit.main() == 2
    assert "FAIL: disk delete" in report.read_text()
