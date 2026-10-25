import json
import os

from bind import disk, request


def remove_empty_target(prefix, name, uid):
    path = prefix + "/persistentvolumeclaims/" + name
    claim = request(path)
    if claim is None:
        return
    if not (
        claim["metadata"]["uid"] == uid
        and claim.get("status", {}).get("phase") == "Pending"
        and not any(
            claim["spec"].get(key)
            for key in ("volumeName", "dataSource", "dataSourceRef")
        )
    ):
        raise RuntimeError("target is not the exact empty unbound claim")
    for pod in request(prefix + "/pods")["items"]:
        if pod.get("status", {}).get("phase") in ("Succeeded", "Failed"):
            continue
        if any(
            v.get("persistentVolumeClaim", {}).get("claimName") == name
            for v in pod["spec"].get("volumes", [])
        ):
            raise RuntimeError("a pod still references the empty target")
    request(
        path,
        "DELETE",
        {
            "preconditions": {
                "uid": uid,
                "resourceVersion": claim["metadata"]["resourceVersion"],
            }
        },
    )


def main():
    plan = json.loads(os.environ["PLAN"])
    if not (
        plan.get("resumeVerified") is True
        and plan.get("copyVerified") is True
        and plan.get("snapshot")
        and plan.get("snapshotStatus") == "READY"
        and plan.get("snapshotSourceDiskId")
        and plan.get("sourceDiskDeletedId") == plan["snapshotSourceDiskId"]
    ):
        raise RuntimeError("healthy cutover and exact cloud deletion receipt required")
    prefix = "/api/v1/namespaces/" + plan["namespace"]
    claim = request(prefix + "/persistentvolumeclaims/" + plan["name"])
    if not (
        claim
        and claim["metadata"]["uid"] == plan["currentUID"]
        and claim["spec"].get("volumeName") == plan["targetPV"]
        and claim.get("status", {}).get("phase") == "Bound"
    ):
        raise RuntimeError("healthy replacement binding changed")
    if plan.get("previousEmptyTarget"):
        remove_empty_target(
            prefix, plan["previousEmptyTarget"], plan["previousEmptyTargetUID"]
        )
    path = "/api/v1/persistentvolumes/" + plan["sourcePV"]
    pv = request(path)
    if pv is None:
        print("Original PV already removed", flush=True)
        return
    if not (
        pv["metadata"]["uid"] == plan["sourcePVUID"]
        and disk(pv) == plan["sourceDisk"]
        and pv["spec"].get("persistentVolumeReclaimPolicy") == "Retain"
        and pv["spec"].get("claimRef", {}).get("uid") == plan["sourceUID"]
        and pv.get("status", {}).get("phase") == "Released"
    ):
        raise RuntimeError("original volume identity or release state changed")
    request(
        path,
        "DELETE",
        {
            "preconditions": {
                "uid": pv["metadata"]["uid"],
                "resourceVersion": pv["metadata"]["resourceVersion"],
            }
        },
    )
    print("Removed exact obsolete PV after cloud disk deletion", flush=True)


if __name__ == "__main__":
    main()
