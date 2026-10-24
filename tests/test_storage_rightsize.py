import importlib.util
from pathlib import Path

import pytest
from test_homechef_park import render

SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "charts/infrastructure/storage-rightsize/files/copy.py"
)


def module():
    spec = importlib.util.spec_from_file_location("rightsize_copy", SCRIPT)
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
    assert cluster["spec"]["storage"]["size"] == "200Gi"
    docs = render("charts/thirdparty/mongodb-blog")
    statefulset = next(d for d in docs if d["kind"] == "StatefulSet")
    assert statefulset["spec"]["replicas"] == 0
    assert (
        statefulset["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"][
            "storage"
        ]
        == "120Gi"
    )
