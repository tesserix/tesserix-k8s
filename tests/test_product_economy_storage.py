import pytest

from test_homechef_park import render


@pytest.mark.parametrize(
    "chart",
    [
        "planning-poker",
        "helivanta",
        "devai",
        "dwellm8",
        "dwellm8-temporal",
        "kora",
        "mark8ly",
        "postiz",
        "roamie",
        "support-platform",
        "tesserix",
        "homechef",
    ],
)
def test_product_database_uses_standard_disks_and_pauses_without_deletion(chart):
    path = f"charts/apps/{chart}-postgres"
    docs = render(path, overrides=("storageMigrationPhase=quiesce",))
    cluster = next(d for d in docs if d["kind"] == "Cluster")
    assert cluster["spec"]["storage"]["storageClass"] == "economy-rwo-retain"
    assert cluster["spec"]["walStorage"]["storageClass"] == "economy-rwo-retain"
    assert cluster["metadata"]["annotations"]["cnpg.io/hibernation"] == "on"
    docs = render(path, overrides=("storageMigrationPhase=copy",))
    cluster = next(d for d in docs if d["kind"] == "Cluster")
    assert (
        cluster["metadata"]["annotations"]["cnpg.io/reconciliationLoop"] == "disabled"
    )


def test_completed_economy_migration_has_no_remaining_jobs_or_permissions():
    docs = render("charts/infrastructure/storage-rightsize")
    assert docs == []


def test_prepare_allocates_retained_standard_targets_without_copy_or_cutover(tmp_path):
    import subprocess
    import yaml

    values = {
        "economy": {
            "phase": "prepare",
            "volumes": [
                {
                    "namespace": "planning-poker",
                    "name": "db-1",
                    "sourceUID": "source",
                    "sourcePV": "pv-source",
                    "target": "eco-db-1",
                    "size": "10Gi",
                    "storageClass": "economy-rwo-retain",
                }
            ],
        }
    }
    config = tmp_path / "values.yaml"
    config.write_text(yaml.safe_dump(values))
    docs = [
        d
        for d in yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "economy",
                    "charts/infrastructure/storage-rightsize",
                    "-f",
                    str(config),
                ],
                text=True,
            )
        )
        if d
    ]
    claims = [d for d in docs if d["kind"] == "PersistentVolumeClaim"]
    assert len(claims) == 1
    assert claims[0]["spec"]["storageClassName"] == "economy-rwo-retain"
    assert (
        claims[0]["metadata"]["annotations"]["argocd.argoproj.io/sync-options"]
        == "Prune=false,Delete=false"
    )
    assert not any(d["kind"] == "Job" for d in docs)
    roles = [d for d in docs if d["kind"] in ("Role", "ClusterRole")]
    assert all(
        not ({"patch", "delete", "create"} & set(r["verbs"]))
        for d in roles
        for r in d["rules"]
    )


def test_copy_uses_recorded_identity_and_read_only_source(tmp_path):
    import subprocess
    import yaml

    config = tmp_path / "copy.yaml"
    config.write_text(
        yaml.safe_dump(
            {
                "economy": {
                    "phase": "copy",
                    "volumes": [
                        {
                            "namespace": "planning-poker",
                            "name": "db-1",
                            "sourceUID": "source",
                            "sourcePV": "old",
                            "target": "eco-db-1",
                            "targetUID": "target",
                            "size": "10Gi",
                            "storageClass": "economy-rwo-retain",
                            "copyJob": "eco-db-1-copy",
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
                    "economy",
                    "charts/infrastructure/storage-rightsize",
                    "-f",
                    str(config),
                ],
                text=True,
            )
        )
        if d
    ]
    jobs = [d for d in docs if d["kind"] == "Job"]
    assert len(jobs) == 1
    pod = jobs[0]["spec"]["template"]["spec"]
    container = pod["containers"][0]
    env = {x["name"]: x.get("value") for x in container["env"]}
    assert env["SOURCE_UID"] == "source" and env["TARGET_UID"] == "target"
    assert next(v for v in container["volumeMounts"] if v["name"] == "source")[
        "readOnly"
    ]
    assert next(v for v in pod["volumes"] if v["name"] == "source")[
        "persistentVolumeClaim"
    ]["readOnly"]
    assert all(
        r["verbs"] == ["get"] or r["verbs"] == ["get", "list"]
        for d in docs
        if d["kind"] == "Role"
        for r in d["rules"]
    )


def test_cutover_requires_verified_copy_and_ready_snapshot(tmp_path):
    import subprocess
    import yaml

    value = {
        "namespace": "planning-poker",
        "name": "db-1",
        "sourceUID": "source",
        "sourcePV": "old",
        "sourceDisk": "disk-old",
        "target": "eco-db-1",
        "targetUID": "target",
        "targetPV": "new",
        "targetDisk": "disk-new",
        "size": "10Gi",
        "storageClass": "economy-rwo-retain",
        "copyJob": "eco-db-1-copy",
        "copyJobs": ["eco-db-1-copy"],
        "cluster": "db",
        "snapshot": "backup",
        "snapshotStatus": "CREATING",
        "copyVerified": False,
    }
    config = tmp_path / "cutover.yaml"
    command = [
        "helm",
        "template",
        "economy",
        "charts/infrastructure/storage-rightsize",
        "-f",
        str(config),
    ]
    config.write_text(
        yaml.safe_dump({"economy": {"phase": "cutover", "volumes": [value]}})
    )
    failed = subprocess.run(command, capture_output=True, text=True)
    assert (
        failed.returncode != 0 and "verified copy and READY snapshot" in failed.stderr
    )
    value.update(snapshotStatus="READY", copyVerified=True)
    config.write_text(
        yaml.safe_dump({"economy": {"phase": "cutover", "volumes": [value]}})
    )
    docs = [
        d for d in yaml.safe_load_all(subprocess.check_output(command, text=True)) if d
    ]
    assert len([d for d in docs if d["kind"] == "Job"]) == 1
    pvs = next(d for d in docs if d["kind"] == "ClusterRole")
    assert pvs["rules"] == [
        {
            "apiGroups": [""],
            "resources": ["persistentvolumes"],
            "verbs": ["get", "patch"],
            "resourceNames": ["old", "new"],
        }
    ]
