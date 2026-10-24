import copy
import json
import os

from bind import request, wait_deleted


def validate_cluster(cluster, uid):
    annotations = cluster["metadata"].get("annotations", {})
    if cluster["metadata"]["uid"] != uid:
        raise RuntimeError("cluster identity changed")
    if (
        annotations.get("cnpg.io/hibernation") != "on"
        or annotations.get("cnpg.io/reconciliationLoop") != "disabled"
    ):
        raise RuntimeError("cluster must be hibernated with reconciliation disabled")
    if not cluster.get("status", {}).get("currentPrimary"):
        raise RuntimeError("known current primary is required")


def main():
    plan = json.loads(os.environ["PLAN"])
    ns, name = plan["namespace"], plan["name"]
    path = "/apis/postgresql.cnpg.io/v1/namespaces/" + ns + "/clusters/" + name
    cm_path = "/api/v1/namespaces/" + ns + "/configmaps/rightsize-cluster-recovery"
    saved = request(cm_path)
    current = request(path)
    if saved is None:
        validate_cluster(current, plan["uid"])
        for pod in request("/api/v1/namespaces/" + ns + "/pods")["items"]:
            claims = {claim["name"] for claim in plan["claims"]}
            if any(
                volume.get("persistentVolumeClaim", {}).get("claimName") in claims
                for volume in pod["spec"].get("volumes", [])
            ) and pod.get("status", {}).get("phase") not in ("Succeeded", "Failed"):
                raise RuntimeError("database pod remains active")
        saved = request(
            cm_path.rsplit("/", 1)[0],
            "POST",
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {"name": "rightsize-cluster-recovery", "namespace": ns},
                "data": {"cluster.json": json.dumps(current)},
            },
        )
    original = json.loads(saved["data"]["cluster.json"])
    validate_cluster(original, plan["uid"])
    if current and current["metadata"]["uid"] == plan["uid"]:
        validate_cluster(current, plan["uid"])
        request(
            path,
            "DELETE",
            {"preconditions": {"uid": plan["uid"]}, "propagationPolicy": "Orphan"},
        )
        wait_deleted(path)
        current = None
    if current is None:
        current = request(path)
    if current is None:
        replacement = {
            "apiVersion": original["apiVersion"],
            "kind": "Cluster",
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": original["metadata"]["annotations"],
                "labels": original["metadata"].get("labels", {}),
            },
            "spec": copy.deepcopy(original["spec"]),
        }
        replacement["spec"]["storage"]["size"] = "60Gi"
        current = request(path.rsplit("/", 1)[0], "POST", replacement)
    validate_cluster(
        {**current, "status": original["status"]}, current["metadata"]["uid"]
    )
    if current["spec"]["storage"]["size"] != "60Gi":
        raise RuntimeError("replacement cluster has incorrect storage size")
    request(path + "/status", "PATCH", {"status": original["status"]})
    owner = {
        "apiVersion": original["apiVersion"],
        "kind": "Cluster",
        "name": name,
        "uid": current["metadata"]["uid"],
        "controller": True,
        "blockOwnerDeletion": True,
    }
    for claim in plan["claims"]:
        pvc_path = (
            "/api/v1/namespaces/" + ns + "/persistentvolumeclaims/" + claim["name"]
        )
        pvc = request(pvc_path)
        if pvc["metadata"]["uid"] != claim["uid"]:
            raise RuntimeError("original claim identity changed")
        request(pvc_path, "PATCH", {"metadata": {"ownerReferences": [owner]}})
    restored = request(path)
    if restored["status"]["currentPrimary"] != original["status"]["currentPrimary"]:
        raise RuntimeError("primary identity was not preserved")
    print(
        "Cluster metadata recreated at 60Gi; primary preserved, reconciliation disabled, all children retained",
        flush=True,
    )


if __name__ == "__main__":
    main()
