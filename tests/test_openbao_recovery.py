import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parents[1] / "charts/thirdparty/openbao/files/recovery.py"


def module():
    spec = importlib.util.spec_from_file_location("recovery", SCRIPT)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def entry(index):
    return {
        "id": f"20260927T{index:02d}0000Z-0123456789ab",
        "created": f"2026-09-27T{index:02d}:00:00Z",
        "verified": True,
    }


def test_catalog_keeps_three_latest_verified_backups_and_is_idempotent():
    m = module()
    retained, removed = m.select_backups([entry(1), entry(2), entry(3)], entry(4))
    assert retained == [entry(4), entry(3), entry(2)]
    assert removed == [entry(1)]
    assert m.select_backups(retained, entry(4)) == (retained, [])


def test_failed_verification_never_replaces_good_backups():
    m = module()
    candidate = {**entry(4), "verified": False}
    with pytest.raises(m.RecoveryError):
        m.select_backups([entry(1), entry(2), entry(3)], candidate)


def test_snapshot_shape_rejects_truncation_and_path_traversal(tmp_path):
    import io
    import tarfile

    m = module()
    bad = tmp_path / "bad.snap"
    bad.write_bytes(b"not a snapshot")
    with pytest.raises(m.RecoveryError):
        m.validate_snapshot(bad)
    with tarfile.open(bad, "w:gz") as archive:
        data = b"private"
        info = tarfile.TarInfo("../outside")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    with pytest.raises(m.RecoveryError):
        m.validate_snapshot(bad)


def test_catalog_rejects_untrusted_object_names():
    m = module()
    with pytest.raises(m.RecoveryError):
        m.validate_catalog(
            {"schema": 1, "backups": [{**entry(1), "object": "../platform/key"}]}
        )


def test_restore_configuration_cannot_join_or_listen_on_production_network(tmp_path):
    m = module()
    config = m.restore_config(tmp_path, "p", "asia-south1", "ring", "key")
    assert config["listener"]["tcp"]["address"] == "127.0.0.1:18230"
    assert config["storage"]["raft"]["path"] == str(tmp_path / "raft")
    assert "retry_join" not in config["storage"]["raft"]
    assert "service_registration" not in config


def complete_entry(index):
    value = entry(index)
    return {
        **value,
        "object": f"snapshots/{value['id']}.snap",
        "generation": str(index),
        "sha256": "a" * 64,
        "marker_sha256": "b" * 64,
        "marker_version": index,
    }


def test_failed_pruning_is_retried_after_catalog_commit(monkeypatch):
    import json

    m = module()
    catalog = {"schema": 1, "backups": [complete_entry(i) for i in (3, 2, 1)]}
    deleted = []
    fail_delete = True

    def request(self, method, url, data=None, headers=None):
        nonlocal catalog, fail_delete
        if method == "GET" and "alt=media" in url:
            return 200, json.dumps(catalog).encode()
        if method == "GET":
            return 200, json.dumps(
                {"generation": "7", "kmsKeyName": "key/cryptoKeyVersions/1"}
            ).encode()
        if method == "POST":
            catalog = json.loads(data)
            return 200, b"{}"
        if fail_delete:
            fail_delete = False
            raise m.RecoveryError("Storage temporarily unavailable")
        deleted.append(url)
        return 204, b""

    monkeypatch.setattr(m.Http, "request", request)
    monkeypatch.setattr(m.subprocess, "check_output", lambda *args, **kwargs: "token")
    store = m.Storage("recovery-bucket", "key")
    with pytest.raises(m.RecoveryError):
        store.publish(complete_entry(4))
    assert [b["id"] for b in catalog["backups"]] == [
        complete_entry(i)["id"] for i in (4, 3, 2)
    ]
    store.publish(complete_entry(4))
    assert len(deleted) == 1
    assert "ifGenerationMatch=1" in deleted[0]


def test_recovery_chart_is_isolated_and_runs_twice_daily():
    import subprocess

    import yaml

    root = SCRIPT.parents[4]
    rendered = subprocess.check_output(
        [
            "helm",
            "template",
            "openbao",
            str(root / "charts/thirdparty/openbao"),
            "--namespace",
            "openbao",
            "--set",
            "recovery.enabled=true",
        ],
        text=True,
    )
    documents = [d for d in yaml.safe_load_all(rendered) if d]
    jobs = {d["metadata"]["name"]: d for d in documents if d["kind"] == "CronJob"}
    backup = jobs["openbao-verified-backup"]
    assert backup["metadata"]["namespace"] == "openbao-recovery"
    assert backup["spec"]["schedule"] == "0 3,15 * * *"
    assert backup["spec"]["timeZone"] == "Etc/UTC"
    spec = backup["spec"]["jobTemplate"]["spec"]
    assert spec["activeDeadlineSeconds"] == 900
    pod = spec["template"]["spec"]
    assert pod["serviceAccountName"] == "openbao-backup"
    assert "cp /usr/bin/bao /tools/bao" in pod["initContainers"][0]["command"][2]
    assert pod["securityContext"]["runAsNonRoot"] is True
    assert all(
        "@sha256:" in c["image"] for c in pod["containers"] + pod["initContainers"]
    )
    restore = jobs["openbao-restore-test"]["spec"]
    assert restore["suspend"] is True
    assert (
        restore["jobTemplate"]["spec"]["template"]["spec"]["serviceAccountName"]
        == "openbao-restore-test"
    )
    assert not any(
        d["kind"] == "Service" and d["metadata"].get("namespace") == "openbao-recovery"
        for d in documents
    )


def test_catalog_refuses_to_delete_a_retained_generation():
    m = module()
    with pytest.raises(m.RecoveryError, match="Retained backup"):
        m.validate_catalog(
            {
                "schema": 1,
                "backups": [complete_entry(1)],
                "pending_deletions": [complete_entry(1)],
            }
        )


def test_catalog_cas_conflict_does_not_delete_anything(monkeypatch):
    import json

    m = module()
    deleted = []

    def request(self, method, url, data=None, headers=None):
        if method == "DELETE":
            deleted.append(url)
            return 204, b""
        if method == "POST":
            return 412, b""
        value = (
            {"schema": 1, "backups": [complete_entry(i) for i in (3, 2, 1)]}
            if "alt=media" in url
            else {"generation": "7", "kmsKeyName": "key/cryptoKeyVersions/1"}
        )
        return 200, json.dumps(value).encode()

    monkeypatch.setattr(m.Http, "request", request)
    monkeypatch.setattr(m.subprocess, "check_output", lambda *args, **kwargs: "token")
    with pytest.raises(m.RecoveryError, match="Concurrent catalog"):
        m.Storage("recovery-bucket", "key").publish(complete_entry(4))
    assert deleted == []


def test_late_publisher_cannot_resurrect_pruned_snapshot(monkeypatch):
    import json

    m = module()
    mutations = []

    def request(self, method, url, data=None, headers=None):
        if method != "GET":
            mutations.append(method)
        value = (
            {"schema": 1, "backups": [complete_entry(i) for i in (4, 3, 2)]}
            if "alt=media" in url
            else {"generation": "7", "kmsKeyName": "key/cryptoKeyVersions/1"}
        )
        return 200, json.dumps(value).encode()

    monkeypatch.setattr(m.Http, "request", request)
    monkeypatch.setattr(m.subprocess, "check_output", lambda *args, **kwargs: "token")
    with pytest.raises(m.RecoveryError, match="superseded"):
        m.Storage("recovery-bucket", "key").publish(complete_entry(1))
    assert mutations == []


def test_corrupted_snapshot_checksums_are_rejected(tmp_path):
    import hashlib
    import io
    import tarfile

    m = module()
    snapshot = tmp_path / "corrupt.snap"
    members = {
        "meta.json": b"{}",
        "state.bin": b"changed",
        "SHA256SUMS.sealed": b"seal",
    }
    members["SHA256SUMS"] = (
        hashlib.sha256(b"{}").hexdigest()
        + "  meta.json\n"
        + hashlib.sha256(b"original").hexdigest()
        + "  state.bin\n"
    ).encode()
    with tarfile.open(snapshot, "w:gz") as archive:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    with pytest.raises(m.RecoveryError, match="checksum mismatch"):
        m.validate_snapshot(snapshot)


def test_verified_backup_alert_detects_missing_success_metrics():
    import subprocess

    import yaml

    rendered = subprocess.check_output(
        [
            "helm",
            "template",
            "openbao",
            str(SCRIPT.parents[1]),
            "--namespace",
            "openbao",
            "--set",
            "recovery.enabled=true",
        ],
        text=True,
    )
    documents = [d for d in yaml.safe_load_all(rendered) if d]
    rules = [
        r
        for d in documents
        if d["kind"] == "PrometheusRule"
        for g in d["spec"]["groups"]
        for r in g["rules"]
    ]
    stale = next(r for r in rules if r["alert"] == "OpenBaoVerifiedBackupStale")
    assert "absent(" in stale["expr"]
    assert "50400" in stale["expr"]
    assert 'namespace="openbao-recovery"' in stale["expr"]
    assert stale["annotations"]["runbook_url"].endswith("openbao-recovery.md")


def test_orphan_cleanup_only_deletes_older_snapshot_generations(monkeypatch):
    import json

    m = module()
    deleted = []
    retained = [complete_entry(i) for i in (4, 3, 2)]
    catalog = {"schema": 1, "backups": retained}
    objects = [
        {
            "name": complete_entry(i)["object"],
            "generation": str(i),
            "timeCreated": complete_entry(i)["created"],
        }
        for i in (1, 2, 3, 4, 5)
    ]
    objects.append(
        {
            "name": "unrelated-file",
            "generation": "6",
            "timeCreated": complete_entry(1)["created"],
        }
    )

    def request(self, method, url, data=None, headers=None):
        if method == "DELETE":
            deleted.append(url)
            return 204, b""
        if "prefix=" in url:
            return 200, json.dumps({"items": objects}).encode()
        if "alt=media" in url:
            return 200, json.dumps(catalog).encode()
        return 200, json.dumps(
            {"generation": "7", "kmsKeyName": "key/cryptoKeyVersions/1"}
        ).encode()

    monkeypatch.setattr(m.Http, "request", request)
    monkeypatch.setattr(m.subprocess, "check_output", lambda *args, **kwargs: "token")
    m.Storage("recovery-bucket", "key").prune_orphans()
    assert len(deleted) == 1
    assert "ifGenerationMatch=1" in deleted[0]


def test_cli_reports_safe_failure_reason_without_echoing_input(monkeypatch, capsys):
    import json
    import sys

    m = module()
    monkeypatch.setattr(sys, "argv", ["recovery.py", "backup"])
    monkeypatch.setenv("BACKUP_BUCKET", "invalid-private-input!")
    monkeypatch.setenv("BACKUP_KMS_KEY", "key")
    assert m.main() == 1
    output = capsys.readouterr().out
    assert "invalid-private-input" not in output
    assert json.loads(output)["error"] == "Invalid recovery bucket"


def test_restore_identities_can_read_unseal_key_metadata_at_key_scope():
    root = SCRIPT.parents[4]
    source = (root / "terraform-new/stacks/03-storage/openbao-recovery.tf").read_text()
    block = source.split(
        'resource "google_kms_crypto_key_iam_member" "openbao_recovery_unseal_metadata" {'
    )[1].split("\n}")[0]
    assert 'role          = "roles/cloudkms.viewer"' in block
    assert "cryptoKeys/openbao-unseal-key" in block
    assert "for_each      = google_service_account.openbao_recovery" in block


def test_legacy_schedule_is_suspended_after_verified_backup_cutover():
    import subprocess

    import yaml

    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "openbao",
                    str(SCRIPT.parents[1]),
                    "--namespace",
                    "openbao",
                ],
                text=True,
            )
        )
    )
    legacy = next(
        d
        for d in docs
        if d
        and d["kind"] == "CronJob"
        and d["metadata"]["name"] == "openbao-snapshot-backup"
    )
    assert legacy["spec"]["suspend"] is True


def test_console_job_creation_requires_admission_policies_for_both_templates():
    import subprocess

    import yaml

    docs = [
        d
        for d in yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "openbao",
                    str(SCRIPT.parents[1]),
                    "--namespace",
                    "openbao",
                ],
                text=True,
            )
        )
        if d
    ]
    policy = next(d for d in docs if d["kind"] == "ValidatingAdmissionPolicy")
    assert policy["spec"]["failurePolicy"] == "Fail"
    assert (
        "system:serviceaccount:secret-service:secret-service-api"
        in policy["spec"]["matchConditions"][0]["expression"]
    )
    bindings = [d for d in docs if d["kind"] == "ValidatingAdmissionPolicyBinding"]
    assert {b["spec"]["paramRef"]["name"] for b in bindings} == {
        "openbao-verified-backup",
        "openbao-restore-test",
    }
    assert all(
        b["spec"]["validationActions"] == ["Deny"]
        and b["spec"]["paramRef"]["parameterNotFoundAction"] == "Deny"
        for b in bindings
    )
    role = next(
        d
        for d in docs
        if d["kind"] == "Role" and d["metadata"]["name"] == "openbao-console-recovery"
    )
    assert role["metadata"]["namespace"] == "openbao-recovery"
    assert all(
        "secrets" not in r["resources"] and "*" not in r["verbs"] for r in role["rules"]
    )
