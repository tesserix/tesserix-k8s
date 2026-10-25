import importlib.util
import sys
from pathlib import Path

import pytest
from test_homechef_park import ROOT, render

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


def test_active_databases_resume_on_smaller_claims():
    docs = render("charts/apps/mark8ly-postgres")
    cluster = next(d for d in docs if d["kind"] == "Cluster")
    assert cluster["metadata"]["annotations"]["cnpg.io/hibernation"] == "off"
    assert cluster["spec"]["storage"]["size"] == "60Gi"
    docs = render("charts/thirdparty/mongodb-blog")
    statefulset = next(d for d in docs if d["kind"] == "StatefulSet")
    assert statefulset["spec"]["replicas"] == 1
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
        "/api/v1/namespaces/db/pods": {
            "items": [
                {
                    "metadata": {"name": "pooler", "labels": {"cnpg.io/cluster": "db"}},
                    "spec": {"volumes": []},
                    "status": {"phase": "Running"},
                }
            ]
        },
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
    retained_claim = state.pop(pvc_path)
    recreate.main()
    state[pvc_path] = retained_claim
    assert deleted == [cluster_path]
    assert state[cluster_path]["spec"]["storage"]["size"] == "60Gi"
    assert state[cluster_path]["status"]["currentPrimary"] == "db-3"
    assert state[pvc_path]["metadata"]["uid"] == "data-uid"
    assert state[pvc_path]["metadata"]["ownerReferences"][0]["uid"] == "new"
    assert (
        json.loads(state[cm_path]["data"]["cluster.json"])["metadata"]["uid"] == "old"
    )


def test_binding_does_not_mutate_when_cluster_recreation_failed(monkeypatch):
    import json

    bind = module(SCRIPT.with_name("bind.py"))
    calls = []

    def api(path, method="GET", body=None):
        calls.append(method)
        return {"status": {"failed": 1}}

    monkeypatch.setattr(bind, "request", api)
    monkeypatch.setenv(
        "PLAN",
        json.dumps(
            {
                "namespace": "db",
                "name": "data",
                "target": "temporary",
                "recreateJob": "recreate",
            }
        ),
    )
    with pytest.raises(RuntimeError, match="recreation failed"):
        bind.main()
    assert calls == ["GET"]


def test_binding_refuses_unfrozen_cluster_before_any_mutation(monkeypatch):
    import json

    bind = module(SCRIPT.with_name("bind.py"))
    plan = {
        "namespace": "db",
        "name": "data",
        "target": "temporary",
        "cluster": "db",
        "sourceUID": "source",
        "targetUID": "target",
        "sourcePV": "old",
        "targetPV": "new",
        "sourceDisk": "old-disk",
        "targetDisk": "new-disk",
        "snapshot": "snapshot",
        "snapshotStatus": "READY",
        "copyVerified": True,
        "copyJob": "verify",
    }

    def api(path, method="GET", body=None):
        assert method == "GET", (
            "mutation attempted before validating the cluster freeze"
        )
        if "/clusters/" in path:
            return {
                "metadata": {
                    "annotations": {
                        "cnpg.io/hibernation": "on",
                        "cnpg.io/reconciliationLoop": "enabled",
                    }
                }
            }
        if path.endswith("/data"):
            return {"metadata": {"uid": "source"}, "spec": {"volumeName": "old"}}
        if path.endswith("/temporary"):
            return {"metadata": {"uid": "target"}, "spec": {"volumeName": "new"}}
        if "/persistentvolumes/" in path:
            source = path.endswith("/old")
            return {
                "spec": {
                    "csi": {"volumeHandle": "old-disk" if source else "new-disk"},
                    "claimRef": {"uid": "source" if source else "target"},
                }
            }
        if "/jobs/" in path:
            return {"status": {"succeeded": 1}}
        if path.endswith("/pods"):
            return {"items": []}
        raise AssertionError(path)

    monkeypatch.setenv("PLAN", json.dumps(plan))
    monkeypatch.setattr(bind, "request", api)
    with pytest.raises(RuntimeError, match="disabled"):
        bind.main()


def test_child_adoption_uses_metadata_only_and_refuses_other_owners(monkeypatch):
    import json

    adopt = module(SCRIPT.with_name("adopt.py"))
    patches = []

    def api(path, method="GET", body=None, metadata=False):
        if "/clusters/" in path:
            return {"metadata": {"uid": "cluster"}}
        assert metadata is True
        if method == "PATCH":
            patches.append(body)
            assert set(body) == {"metadata"}
            return {}
        return {
            "metadata": {
                "uid": "child",
                "resourceVersion": "1",
                "ownerReferences": [{"kind": "ExternalSecret"}],
            }
        }

    monkeypatch.setattr(adopt, "request", api)
    monkeypatch.setenv(
        "PLAN",
        json.dumps(
            {
                "namespace": "db",
                "name": "db",
                "currentUID": "cluster",
                "children": [{"path": "/secret", "uid": "child"}],
            }
        ),
    )
    with pytest.raises(RuntimeError, match="different owner"):
        adopt.main()
    assert patches == []


def test_openpanel_uses_the_verified_120gi_disk_under_existing_claim_name():
    docs = render("charts/thirdparty/openpanel", "values-prod.yaml")
    pvc = next(d for d in docs if d["kind"] == "PersistentVolumeClaim")
    assert pvc["spec"]["resources"]["requests"]["storage"] == "120Gi"
    assert pvc["spec"]["volumeName"] == "pvc-397dbafb-8c71-4762-8a5f-99fa7fa08cc2"
    deployment = next(
        d
        for d in docs
        if d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-clickhouse")
    )
    assert any(
        v.get("persistentVolumeClaim", {}).get("claimName") == pvc["metadata"]["name"]
        for v in deployment["spec"]["template"]["spec"]["volumes"]
    )


def test_blog_backup_creates_the_service_account_used_by_its_job():
    import subprocess

    import yaml

    app = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/mongodb-blog-backup.yaml").read_text()
    )
    values = app["spec"]["source"]["helm"]["values"]
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "mongodb-blog-backup",
                    str(ROOT / "charts/thirdparty/mongodb-backup"),
                    "--values",
                    "-",
                ],
                input=values,
                text=True,
            )
        )
    )
    account = next(d for d in docs if d and d["kind"] == "ServiceAccount")
    cron = next(d for d in docs if d and d["kind"] == "CronJob")
    assert (
        account["metadata"]["name"]
        == cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["serviceAccountName"]
        == "postgres-backup"
    )
    assert (
        account["metadata"]["annotations"]["iam.gke.io/gcp-service-account"]
        == "postgres-backup-sa@tesseracthub-480811.iam.gserviceaccount.com"
    )


def test_completed_migration_renders_no_jobs_or_temporary_permissions():
    assert render("charts/infrastructure/storage-rightsize") == []


def test_snapshot_verification_runs_on_read_only_volumes_without_repair_or_marker(
    tmp_path, monkeypatch
):
    copy = module()
    source, target = tmp_path / "source", tmp_path / "target"
    source.mkdir()
    target.mkdir()
    for path in (source, target):
        (path / "data").write_bytes(b"offline database")
        (path / "data").chmod(0o440)
        path.chmod(0o550)
    for key, value in {
        "NAMESPACE": "db",
        "SOURCE_CLAIM": "source",
        "SOURCE_UID": "s",
        "TARGET_CLAIM": "target",
        "TARGET_UID": "t",
        "POD_NAME": "verify",
        "VERIFY_ONLY": "true",
    }.items():
        monkeypatch.setenv(key, value)

    def api(path):
        if path.endswith("/pods"):
            return {"items": []}
        return {"metadata": {"uid": "s" if path.endswith("/source") else "t"}}

    monkeypatch.setattr(copy, "api", api)
    try:
        copy.main(source, target)
        assert (target / "data").read_bytes() == b"offline database"
        assert not (target / ".rightsize-verified.json").exists()
        assert target.stat().st_mode == source.stat().st_mode
    finally:
        source.chmod(0o750)
        target.chmod(0o750)


def test_mongo_diagnostic_metadata_exception_never_skips_database_files(
    tmp_path, monkeypatch, capsys
):
    source, target = tmp_path / "source", tmp_path / "target"
    for root in (source, target):
        (root / ".mongodb/mongosh").mkdir(parents=True)
        (root / ".mongodb/mongosh/session_log").write_text("diagnostic")
        (root / "WiredTiger.wt").write_text("database")
    import shutil

    shutil.copystat(
        source / ".mongodb/mongosh/session_log", target / ".mongodb/mongosh/session_log"
    )
    original = Path.open

    def deny_diagnostic(path, *args, **kwargs):
        if path.name == "session_log":
            raise PermissionError("other user")
        return original(path, *args, **kwargs)

    monkeypatch.setattr(Path, "open", deny_diagnostic)
    with pytest.raises(PermissionError):
        module().verify(source, target)
    assert module().verify(source, target, mongo_diagnostics=True) == 1
    assert (
        "Metadata-only mongosh diagnostic: .mongodb/mongosh/session_log"
        in capsys.readouterr().out
    )
    (target / "WiredTiger.wt").write_text("corrupt!")
    with pytest.raises(RuntimeError, match="content mismatch"):
        module().verify(source, target, mongo_diagnostics=True)
