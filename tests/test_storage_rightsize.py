import importlib.util
import sys
from pathlib import Path

import pytest
from test_homechef_park import render

SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "charts/infrastructure/storage-rightsize/files/copy.py"
)


def module(path=SCRIPT):
    sys.path.insert(0, str(SCRIPT.parent))
    spec = importlib.util.spec_from_file_location("rightsize_copy", path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def test_refuses_copy_while_any_other_pod_references_source():
    pod = {
        "metadata": {"name": "database"},
        "status": {"phase": "Running"},
        "spec": {"volumes": [{"persistentVolumeClaim": {"claimName": "data"}}]},
    }
    with pytest.raises(RuntimeError, match="still references"):
        module().assert_quiescent([pod], "data", "copy-job")
    pod["status"]["phase"] = "Succeeded"
    module().assert_quiescent([pod], "data", "copy-job")


def test_verification_detects_corruption_and_preserves_symlinks(tmp_path):
    source, target = tmp_path / "source", tmp_path / "target"
    source.mkdir()
    target.mkdir()
    for directory in [source, target]:
        (directory / "data").write_bytes(b"database bytes")
        (directory / "wal").symlink_to("/wal/pg_wal")
    assert module().verify(source, target) == 1
    (target / "data").write_bytes(b"corrupted bytes")
    with pytest.raises(RuntimeError, match="mismatch"):
        module().verify(source, target)


def test_databases_are_quiesced_without_removing_existing_claims():
    docs = render("charts/apps/mark8ly-postgres")
    cluster = next(d for d in docs if d["kind"] == "Cluster")
    assert cluster["metadata"]["annotations"]["cnpg.io/hibernation"] == "on"
    assert cluster["spec"]["storage"]["size"] == "60Gi"
    docs = render("charts/thirdparty/mongodb-blog")
    statefulset = next(d for d in docs if d["kind"] == "StatefulSet")
    assert statefulset["spec"]["replicas"] == 0
    assert (
        statefulset["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"][
            "storage"
        ]
        == "60Gi"
    )


def test_verification_checks_root_permissions_and_file_types(tmp_path):
    source, target = tmp_path / "source", tmp_path / "target"
    source.mkdir(mode=0o750)
    target.mkdir(mode=0o700)
    with pytest.raises(RuntimeError, match="ownership or mode"):
        module().verify(source, target)
    target.chmod(0o750)
    (source / "data").mkdir()
    (target / "data").write_text("not a directory")
    with pytest.raises(RuntimeError, match="type mismatch"):
        module().verify(source, target, metadata=False)


def test_partial_copy_requires_explicit_retry_and_rechecks_content(
    tmp_path, monkeypatch
):
    source, target = tmp_path / "source", tmp_path / "target"
    source.mkdir()
    target.mkdir()
    import shutil
    import subprocess

    copy = module()
    run = subprocess.run
    executable = shutil.which("gcp") or "cp"
    monkeypatch.setattr(
        copy.subprocess, "run", lambda args, **kw: run([executable, *args[1:]], **kw)
    )
    (source / "data").write_bytes(b"complete database file")
    (target / "data").write_bytes(b"partial")
    with pytest.raises(RuntimeError, match="content mismatch"):
        copy.copy_or_repair(source, target, False)
    copy.copy_or_repair(source, target, True)
    assert module().verify(source, target) == 1


def test_cluster_recreation_requires_hibernation_and_disabled_reconciliation():
    recreate = module(SCRIPT.with_name("recreate.py"))
    cluster = {
        "metadata": {
            "uid": "original",
            "annotations": {
                "cnpg.io/hibernation": "on",
                "cnpg.io/reconciliationLoop": "disabled",
            },
        },
        "status": {"currentPrimary": "db-1"},
    }
    recreate.validate_cluster(cluster, "original")
    cluster["metadata"]["annotations"]["cnpg.io/reconciliationLoop"] = "enabled"
    with pytest.raises(RuntimeError, match="disabled"):
        recreate.validate_cluster(cluster, "original")


def test_cutover_requires_snapshot_successful_copy_and_unchanged_bindings():
    bind = module(SCRIPT.with_name("bind.py"))
    plan = {
        "snapshotStatus": "READY",
        "snapshot": "snapshot-1",
        "sourceUID": "source-uid",
        "targetUID": "target-uid",
        "sourcePV": "old-disk",
        "targetPV": "new-disk",
    }
    source = {"metadata": {"uid": "source-uid"}, "spec": {"volumeName": "old-disk"}}
    target = {"metadata": {"uid": "target-uid"}, "spec": {"volumeName": "new-disk"}}
    bind.validate(plan, source, target, {"status": {"succeeded": 1}})
    with pytest.raises(RuntimeError, match="copy has not succeeded"):
        bind.validate(plan, source, target, {"status": {"failed": 1}})
    with pytest.raises(RuntimeError, match="snapshot"):
        bind.validate(
            {**plan, "snapshotStatus": "CREATING"},
            source,
            target,
            {"status": {"succeeded": 1}},
        )
    with pytest.raises(RuntimeError, match="target identity changed"):
        bind.validate(
            plan,
            source,
            {**target, "metadata": {"uid": "other"}},
            {"status": {"succeeded": 1}},
        )


def test_cluster_cutover_preserves_primary_and_children_and_is_retryable(monkeypatch):
    import copy
    import json

    recreate = module(SCRIPT.with_name("recreate.py"))
    cluster_path = "/apis/postgresql.cnpg.io/v1/namespaces/db/clusters/db"
    cm_path = "/api/v1/namespaces/db/configmaps/rightsize-cluster-recovery"
    pvc_path = "/api/v1/namespaces/db/persistentvolumeclaims/data"
    state = {
        cluster_path: {
            "apiVersion": "postgresql.cnpg.io/v1",
            "kind": "Cluster",
            "metadata": {
                "uid": "old",
                "annotations": {
                    "cnpg.io/hibernation": "on",
                    "cnpg.io/reconciliationLoop": "disabled",
                },
            },
            "spec": {"storage": {"size": "200Gi"}},
            "status": {"currentPrimary": "db-3", "latestGeneratedNode": 3},
        },
        pvc_path: {"metadata": {"uid": "data-uid"}},
        "/api/v1/namespaces/db/pods": {"items": []},
    }
    deleted = []

    def api(path, method="GET", body=None):
        if method == "GET":
            return copy.deepcopy(state.get(path))
        if method == "POST":
            target = path + "/" + body["metadata"]["name"]
            state[target] = copy.deepcopy(body)
            state[target]["metadata"]["uid"] = "new"
            return copy.deepcopy(state[target])
        if method == "DELETE":
            assert body["preconditions"]["uid"] == "old"
            assert body["propagationPolicy"] == "Orphan"
            deleted.append(path)
            del state[path]
            return {}
        if method == "PATCH":
            target = path.removesuffix("/status")
            for k, value in body.items():
                state[target].setdefault(k, {}).update(value)
            return copy.deepcopy(state[target])
        raise AssertionError(method)

    monkeypatch.setenv(
        "PLAN",
        json.dumps(
            {
                "namespace": "db",
                "name": "db",
                "uid": "old",
                "claims": [{"name": "data", "uid": "data-uid"}],
            }
        ),
    )
    monkeypatch.setattr(recreate, "request", api)
    monkeypatch.setattr(recreate, "wait_deleted", lambda path: None)
    recreate.main()
    recreate.main()
    assert deleted == [cluster_path]
    assert state[cluster_path]["spec"]["storage"]["size"] == "60Gi"
    assert state[cluster_path]["status"]["currentPrimary"] == "db-3"
    assert state[pvc_path]["metadata"]["uid"] == "data-uid"
    assert state[pvc_path]["metadata"]["ownerReferences"][0]["uid"] == "new"
    assert (
        json.loads(state[cm_path]["data"]["cluster.json"])["metadata"]["uid"] == "old"
    )
