import json
import os

from bind import disk, request, wait_deleted

PREFIX = "/api/v1/namespaces/homechef"
CLUSTER = "/apis/psmdb.percona.com/v1/namespaces/homechef/perconaservermongodbs/homechef-mongodb"
OPERATOR = "/apis/apps/v1/namespaces/homechef/deployments/homechef-mongodb-operator-psmdb-operator"
CONTROLLER = "/apis/apps/v1/namespaces/homechef/statefulsets/homechef-mongodb-rs0"


def validate(plan, cluster, operator, controller, claims, pvs, pods):
    if not (
        cluster
        and cluster["metadata"]["uid"] == plan["clusterUID"]
        and cluster["spec"].get("pause") is True
        and len(cluster["spec"].get("replsets", [])) == 1
        and cluster["spec"]["replsets"][0]["name"] == "rs0"
        and cluster["spec"]["replsets"][0]["volumeSpec"]["persistentVolumeClaim"][
            "storageClassName"
        ]
        == "economy-rwo-retain"
    ):
        raise RuntimeError("paused exact CR with standard desired storage required")
    if not (
        operator
        and operator["metadata"]["uid"] == plan["operatorUID"]
        and operator["spec"]["replicas"] == 0
        and operator.get("status", {}).get("replicas", 0) == 0
    ):
        raise RuntimeError("exact operator must remain stopped")
    names = {f"mongod-data-homechef-mongodb-rs0-{i}" for i in range(3)}
    if len(plan["volumes"]) != 3 or {v["name"] for v in plan["volumes"]} != names:
        raise RuntimeError("all three verified member claims required")
    for v in plan["volumes"]:
        c, pv = claims.get(v["name"]), pvs.get(v["targetPV"])
        if not (
            v["namespace"] == "homechef"
            and v.get("copyVerified") is True
            and v.get("snapshotStatus") == "READY"
            and v.get("snapshot")
            and c
            and pv
            and c["metadata"]["uid"] == v["currentUID"]
            and not c["metadata"].get("ownerReferences")
            and c["spec"].get("volumeName") == v["targetPV"]
            and c["spec"].get("storageClassName") == "economy-rwo-retain"
            and c.get("status", {}).get("phase") == "Bound"
            and pv.get("status", {}).get("phase") == "Bound"
            and pv["spec"].get("storageClassName") == "economy-rwo-retain"
            and pv["spec"].get("claimRef", {}).get("uid") == v["currentUID"]
            and disk(pv) == v["targetDisk"]
        ):
            raise RuntimeError(
                "verified exact standard binding without controller owner required"
            )
    for p in pods:
        if p.get("status", {}).get("phase") in ("Succeeded", "Failed"):
            continue
        if p["metadata"]["name"].startswith(
            "homechef-mongodb-operator-psmdb-operator-"
        ) or any(
            v.get("persistentVolumeClaim", {}).get("claimName") in names
            for v in p["spec"].get("volumes", [])
        ):
            raise RuntimeError("operator or database volume still active")
    if controller and not (
        controller["metadata"]["uid"] == plan["controllerUID"]
        and controller["spec"]["replicas"] == 0
        and controller["spec"].get("persistentVolumeClaimRetentionPolicy")
        == {"whenDeleted": "Retain", "whenScaled": "Retain"}
        and any(
            ref.get("uid") == plan["clusterUID"]
            and ref.get("kind") == "PerconaServerMongoDB"
            and ref.get("controller") is True
            for ref in controller["metadata"].get("ownerReferences", [])
        )
    ):
        raise RuntimeError("exact stopped retained operator-owned controller required")


def main():
    plan = json.loads(os.environ["PLAN"])
    controller = request(CONTROLLER)
    claims = {
        v["name"]: request(PREFIX + "/persistentvolumeclaims/" + v["name"])
        for v in plan["volumes"]
    }
    pvs = {
        v["targetPV"]: request("/api/v1/persistentvolumes/" + v["targetPV"])
        for v in plan["volumes"]
    }
    validate(
        plan,
        request(CLUSTER),
        request(OPERATOR),
        controller,
        claims,
        pvs,
        request(PREFIX + "/pods")["items"],
    )
    if controller is None:
        print("Parked controller already absent; claims preserved", flush=True)
        return
    request(
        CONTROLLER,
        "DELETE",
        {
            "preconditions": {
                "uid": controller["metadata"]["uid"],
                "resourceVersion": controller["metadata"]["resourceVersion"],
            },
            "propagationPolicy": "Foreground",
        },
    )
    wait_deleted(CONTROLLER)
    print(
        "Removed exact stopped stale controller; CR remains paused and claims preserved",
        flush=True,
    )


if __name__ == "__main__":
    main()
