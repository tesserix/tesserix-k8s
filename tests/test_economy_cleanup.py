import copy
import json

import pytest
from test_storage_rightsize import SCRIPT, module


@pytest.mark.parametrize("verification_key", ["resumeVerified", "parkedVerified"])
def test_cleanup_reclaims_only_exact_released_source_after_verified_state(
    monkeypatch, verification_key
):
    cleanup = module(SCRIPT.with_name("cleanup.py"))
    plan = {
        "namespace": "db",
        "name": "data",
        "currentUID": "current",
        "targetPV": "new",
        "sourcePV": "old",
        "sourcePVUID": "old-pv-uid",
        "sourceUID": "original",
        "sourceDisk": "projects/p/zones/z/disks/old",
        "snapshot": "backup",
        "snapshotStatus": "READY",
        "snapshotSourceDiskId": "123",
        "sourceDiskDeletedId": "123",
        verification_key: True,
        "copyVerified": True,
    }
    state = {
        "/api/v1/namespaces/db/pods": {"items": []},
        "/api/v1/namespaces/db/persistentvolumeclaims/data": {
            "metadata": {"uid": "current"},
            "spec": {"volumeName": "new"},
            "status": {"phase": "Bound"},
        },
        "/api/v1/persistentvolumes/old": {
            "metadata": {"uid": "old-pv-uid", "resourceVersion": "7"},
            "spec": {
                "persistentVolumeReclaimPolicy": "Retain",
                "csi": {"volumeHandle": plan["sourceDisk"]},
                "claimRef": {"uid": "original"},
            },
            "status": {"phase": "Released"},
        },
    }
    mutations = []

    def api(path, method="GET", body=None):
        if method == "DELETE":
            mutations.append((path, body))
            del state[path]
            return {}
        return copy.deepcopy(state.get(path))

    monkeypatch.setattr(cleanup, "request", api)
    for key in (verification_key, "copyVerified", "sourceDiskDeletedId"):
        invalid = {**plan, key: False}
        monkeypatch.setenv("PLAN", json.dumps(invalid))
        with pytest.raises(RuntimeError):
            cleanup.main()
        assert not mutations
    monkeypatch.setenv("PLAN", json.dumps(plan))
    pv = state["/api/v1/persistentvolumes/old"]
    pv["spec"]["claimRef"]["uid"] = "another"
    with pytest.raises(RuntimeError, match="identity"):
        cleanup.main()
    assert not mutations
    pv["spec"]["claimRef"]["uid"] = "original"
    if verification_key == "parkedVerified":
        state["/api/v1/namespaces/db/pods"]["items"] = [
            {
                "status": {"phase": "Running"},
                "spec": {"volumes": [{"persistentVolumeClaim": {"claimName": "data"}}]},
            }
        ]
        with pytest.raises(RuntimeError, match="pod"):
            cleanup.main()
        assert not mutations
        state["/api/v1/namespaces/db/pods"]["items"] = []
    cleanup.main()
    assert mutations == [
        (
            "/api/v1/persistentvolumes/old",
            {"preconditions": {"uid": "old-pv-uid", "resourceVersion": "7"}},
        )
    ]
    cleanup.main()
    assert len(mutations) == 1


def test_empty_target_cleanup_refuses_bound_claims_or_pod_references(monkeypatch):
    cleanup = module(SCRIPT.with_name("cleanup.py"))
    claim = {
        "metadata": {"uid": "empty", "resourceVersion": "3"},
        "spec": {},
        "status": {"phase": "Pending"},
    }
    pod = {
        "spec": {"volumes": [{"persistentVolumeClaim": {"claimName": "empty"}}]},
        "status": {"phase": "Running"},
    }
    calls = []

    def api(path, method="GET", body=None):
        if method == "DELETE":
            calls.append(body)
            return {}
        return {"items": [pod]} if path.endswith("/pods") else claim

    monkeypatch.setattr(cleanup, "request", api)
    with pytest.raises(RuntimeError, match="pod"):
        cleanup.remove_empty_target("/api/v1/namespaces/db", "empty", "empty")
    assert not calls
    pod["status"]["phase"] = "Succeeded"
    claim["spec"]["volumeName"] = "allocated"
    with pytest.raises(RuntimeError, match="empty"):
        cleanup.remove_empty_target("/api/v1/namespaces/db", "empty", "empty")
    assert not calls
    claim["spec"].clear()
    cleanup.remove_empty_target("/api/v1/namespaces/db", "empty", "empty")
    assert calls == [{"preconditions": {"uid": "empty", "resourceVersion": "3"}}]


def test_cleanup_renders_restricted_job_and_only_named_deletion_permissions(tmp_path):
    import subprocess

    import yaml
    from test_homechef_park import ROOT

    config = tmp_path / "cleanup.yaml"
    config.write_text(
        yaml.safe_dump(
            {
                "economy": {
                    "phase": "cleanup",
                    "volumes": [
                        {
                            "namespace": "db",
                            "name": "data",
                            "sourcePV": "old",
                            "targetPV": "new",
                            "target": "snap-data",
                            "previousEmptyTarget": "empty",
                        }
                    ],
                }
            }
        )
    )
    docs = [
        d
        for d in yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "migration",
                    str(ROOT / "charts/infrastructure/storage-rightsize"),
                    "-f",
                    str(config),
                ],
                text=True,
            )
        )
        if d
    ]
    job = next(d for d in docs if d["kind"] == "Job")
    pod = job["spec"]["template"]["spec"]
    assert pod["securityContext"]["runAsNonRoot"] is True
    assert all("persistentVolumeClaim" not in v for v in pod["volumes"])
    role = next(d for d in docs if d["kind"] == "ClusterRole")
    assert role["rules"] == [
        {
            "apiGroups": [""],
            "resources": ["persistentvolumes"],
            "verbs": ["get", "delete"],
            "resourceNames": ["old"],
        }
    ]
    role = next(d for d in docs if d["kind"] == "Role")
    deletions = [r for r in role["rules"] if "delete" in r["verbs"]]
    assert deletions == [
        {
            "apiGroups": [""],
            "resources": ["persistentvolumeclaims"],
            "verbs": ["get", "delete"],
            "resourceNames": ["empty"],
        }
    ]
