import copy
import json

import pytest
from test_homechef_park import ROOT
from test_storage_rightsize import module

SCRIPT = ROOT / "charts/infrastructure/storage-rightsize/files/retire_homechef_mongo.py"


def state():
    plan = {
        "controllerUID": "old-sts",
        "clusterUID": "cr",
        "operatorUID": "operator",
        "volumes": [],
    }
    cluster = {
        "metadata": {"uid": "cr"},
        "spec": {
            "pause": True,
            "replsets": [
                {
                    "name": "rs0",
                    "volumeSpec": {
                        "persistentVolumeClaim": {
                            "storageClassName": "economy-rwo-retain"
                        }
                    },
                }
            ],
        },
    }
    operator = {
        "metadata": {"uid": "operator"},
        "spec": {"replicas": 0},
        "status": {"replicas": 0},
    }
    sts = {
        "metadata": {
            "uid": "old-sts",
            "resourceVersion": "10",
            "ownerReferences": [
                {"uid": "cr", "kind": "PerconaServerMongoDB", "controller": True}
            ],
        },
        "spec": {
            "replicas": 0,
            "persistentVolumeClaimRetentionPolicy": {
                "whenDeleted": "Retain",
                "whenScaled": "Retain",
            },
        },
    }
    claims, pvs = {}, {}
    for i in range(3):
        name = f"mongod-data-homechef-mongodb-rs0-{i}"
        pv, uid, disk = f"pv-{i}", f"claim-{i}", f"disk-{i}"
        plan["volumes"].append(
            {
                "namespace": "homechef",
                "name": name,
                "currentUID": uid,
                "targetPV": pv,
                "targetDisk": disk,
                "copyVerified": True,
                "snapshotStatus": "READY",
                "snapshot": f"snapshot-{i}",
            }
        )
        claims[name] = {
            "metadata": {"uid": uid},
            "spec": {"storageClassName": "economy-rwo-retain", "volumeName": pv},
            "status": {"phase": "Bound"},
        }
        pvs[pv] = {
            "spec": {
                "csi": {"volumeHandle": disk},
                "storageClassName": "economy-rwo-retain",
                "claimRef": {"uid": uid},
            },
            "status": {"phase": "Bound"},
        }
    return plan, cluster, operator, sts, claims, pvs, []


def test_accepts_only_parked_controller_with_all_verified_standard_bindings():
    module(SCRIPT).validate(*state())


@pytest.mark.parametrize(
    "case",
    [
        "cluster_active",
        "cluster_uid",
        "old_class",
        "operator_active",
        "operator_status",
        "operator_uid",
        "controller_active",
        "controller_uid",
        "delete_claims",
        "wrong_owner",
        "claim_uid",
        "claim_owner",
        "disk_changed",
        "missing_volume",
        "unverified",
        "active_pod",
    ],
)
def test_rejects_unsafe_controller_retirement(case):
    plan, cluster, operator, sts, claims, pvs, pods = state()
    if case == "cluster_active":
        cluster["spec"]["pause"] = False
    if case == "cluster_uid":
        cluster["metadata"]["uid"] = "other"
    if case == "old_class":
        cluster["spec"]["replsets"][0]["volumeSpec"]["persistentVolumeClaim"][
            "storageClassName"
        ] = "standard-rwo"
    if case == "operator_active":
        operator["spec"]["replicas"] = 1
    if case == "operator_status":
        operator["status"]["replicas"] = 1
    if case == "operator_uid":
        operator["metadata"]["uid"] = "other"
    if case == "controller_active":
        sts["spec"]["replicas"] = 1
    if case == "controller_uid":
        sts["metadata"]["uid"] = "other"
    if case == "delete_claims":
        sts["spec"]["persistentVolumeClaimRetentionPolicy"]["whenDeleted"] = "Delete"
    if case == "wrong_owner":
        sts["metadata"]["ownerReferences"][0]["uid"] = "other"
    if case == "claim_uid":
        next(iter(claims.values()))["metadata"]["uid"] = "other"
    if case == "claim_owner":
        next(iter(claims.values()))["metadata"]["ownerReferences"] = [
            {"uid": "old-sts"}
        ]
    if case == "disk_changed":
        next(iter(pvs.values()))["spec"]["csi"]["volumeHandle"] = "other"
    if case == "missing_volume":
        plan["volumes"].pop()
    if case == "unverified":
        plan["volumes"][0]["copyVerified"] = False
    if case == "active_pod":
        pods.append(
            {
                "metadata": {"name": "writer"},
                "status": {"phase": "Running"},
                "spec": {
                    "volumes": [
                        {
                            "persistentVolumeClaim": {
                                "claimName": plan["volumes"][0]["name"]
                            }
                        }
                    ]
                },
            }
        )
    with pytest.raises(RuntimeError):
        module(SCRIPT).validate(plan, cluster, operator, sts, claims, pvs, pods)


def test_main_deletes_only_exact_sts_after_all_guards_and_uses_preconditions(
    monkeypatch,
):
    m = module(SCRIPT)
    plan, cluster, operator, sts, claims, pvs, pods = state()
    prefix = "/api/v1/namespaces/homechef"
    path = "/apis/apps/v1/namespaces/homechef/statefulsets/homechef-mongodb-rs0"
    data = {
        m.CLUSTER: cluster,
        m.OPERATOR: operator,
        path: sts,
        prefix + "/pods": {"items": pods},
    }
    data.update({prefix + "/persistentvolumeclaims/" + n: c for n, c in claims.items()})
    data.update({"/api/v1/persistentvolumes/" + n: p for n, p in pvs.items()})
    writes = []

    def request(url, method="GET", body=None):
        if method == "DELETE":
            writes.append((url, copy.deepcopy(body)))
            data.pop(url)
            return {}
        return data.get(url)

    monkeypatch.setattr(m, "request", request)
    monkeypatch.setattr(m, "wait_deleted", lambda url: None)
    monkeypatch.setenv("PLAN", json.dumps(plan))
    operator["spec"]["replicas"] = 1
    with pytest.raises(RuntimeError):
        m.main()
    assert writes == []
    operator["spec"]["replicas"] = 0
    m.main()
    assert writes == [
        (
            path,
            {
                "preconditions": {"uid": "old-sts", "resourceVersion": "10"},
                "propagationPolicy": "Foreground",
            },
        )
    ]


def test_controller_job_permissions_are_exact_and_cannot_modify_claims(tmp_path):
    import yaml
    from test_homechef_park import render

    plan = state()[0]
    p = tmp_path / "retire.yaml"
    p.write_text(
        yaml.safe_dump(
            {
                "economy": {
                    "phase": "retire-homechef-mongo",
                    "volumes": plan["volumes"],
                    "homechefController": {
                        k: plan[k]
                        for k in ["controllerUID", "clusterUID", "operatorUID"]
                    },
                }
            }
        )
    )
    docs = render("charts/infrastructure/storage-rightsize", p)
    job = next(d for d in docs if d["kind"] == "Job")
    assert job["spec"]["template"]["spec"]["securityContext"]["runAsNonRoot"] is True
    assert not any(
        v.get("persistentVolumeClaim")
        for v in job["spec"]["template"]["spec"]["volumes"]
    )
    role = next(d for d in docs if d["kind"] == "Role")
    mutation = [
        (r["resources"], r.get("resourceNames"), r["verbs"])
        for r in role["rules"]
        if any(v in r["verbs"] for v in ["create", "delete", "patch", "update"])
    ]
    assert mutation == [(["statefulsets"], ["homechef-mongodb-rs0"], ["get", "delete"])]
    cluster = next(d for d in docs if d["kind"] == "ClusterRole")
    assert cluster["rules"] == [
        {
            "apiGroups": [""],
            "resources": ["persistentvolumes"],
            "verbs": ["get"],
            "resourceNames": ["pv-0", "pv-1", "pv-2"],
        }
    ]
    assert len([d for d in docs if d["kind"] == "Job"]) == 1
