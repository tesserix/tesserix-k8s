import json
import os
import ssl
import time
import urllib.error
import urllib.request
from pathlib import Path


def request(path, method="GET", body=None):
    mount = Path("/var/run/secrets/kubernetes.io/serviceaccount")
    headers = {"Authorization": "Bearer " + (mount / "token").read_text().strip()}
    if body is not None:
        headers["Content-Type"] = (
            "application/merge-patch+json" if method == "PATCH" else "application/json"
        )
    req = urllib.request.Request(
        "https://" + os.environ["KUBERNETES_SERVICE_HOST"] + path,
        data=None if body is None else json.dumps(body).encode(),
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(
            req,
            context=ssl.create_default_context(cafile=str(mount / "ca.crt")),
            timeout=30,
        ) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404 and method in ("GET", "DELETE"):
            return None
        if error.code == 409 and method == "POST":
            return request(path + "/" + body["metadata"]["name"])
        raise RuntimeError(f"Kubernetes {method} returned HTTP {error.code}") from None


def validate(plan, source, target, job):
    if plan.get("snapshotStatus") != "READY" or not plan.get("snapshot"):
        raise RuntimeError("verified source snapshot is required")
    for claim, key in [(source, "source"), (target, "target")]:
        if claim and claim["metadata"]["uid"] != plan[key + "UID"]:
            raise RuntimeError(key + " identity changed")
        if claim and claim["spec"]["volumeName"] != plan[key + "PV"]:
            raise RuntimeError("volume binding changed")
    if job and job.get("status", {}).get("succeeded") != 1:
        raise RuntimeError("copy has not succeeded")
    if not job and plan.get("copyVerified") is not True:
        raise RuntimeError("copy has not succeeded")


def wait_deleted(path):
    for _ in range(120):
        if request(path) is None:
            return
        time.sleep(3)
    raise RuntimeError("resource deletion did not complete; original disks retained")


def disk(pv):
    spec = pv["spec"]
    return (
        spec["csi"]["volumeHandle"]
        if "csi" in spec
        else spec["gcePersistentDisk"]["pdName"]
    )


def main():
    plan = json.loads(os.environ["PLAN"])
    prefix = "/api/v1/namespaces/" + plan["namespace"]
    source_path = prefix + "/persistentvolumeclaims/" + plan["name"]
    target_path = prefix + "/persistentvolumeclaims/" + plan["target"]
    job_prefix = "/apis/batch/v1/namespaces/" + plan["namespace"] + "/jobs/"
    source, target = request(source_path), request(target_path)
    if plan.get("copyVerified") is not True or plan.get("snapshotStatus") != "READY":
        raise RuntimeError("verified copy and snapshot evidence required")
    for name, handle in [
        (plan["sourcePV"], plan["sourceDisk"]),
        (plan["targetPV"], plan["targetDisk"]),
    ]:
        pv = request("/api/v1/persistentvolumes/" + name)
        if disk(pv) != handle:
            raise RuntimeError("physical disk identity changed")
    if source and source["spec"].get("volumeName") == plan["targetPV"]:
        if source.get("status", {}).get("phase") != "Bound":
            raise RuntimeError("replacement exists but is not bound")
        print("Replacement already bound; no mutation required", flush=True)
        return
    validate(plan, source, target, request(job_prefix + plan["copyJob"]))
    for pod in request(prefix + "/pods")["items"]:
        if pod.get("status", {}).get("phase") in ("Succeeded", "Failed"):
            continue
        if any(
            v.get("persistentVolumeClaim", {}).get("claimName")
            in (plan["name"], plan["target"])
            for v in pod["spec"].get("volumes", [])
        ):
            raise RuntimeError("a pod still references a migration volume")
    for name in (plan["sourcePV"], plan["targetPV"]):
        pv = request("/api/v1/persistentvolumes/" + name)
        ref = pv["spec"].get("claimRef", {})
        if ref.get("uid") not in (None, plan["sourceUID"], plan["targetUID"]):
            raise RuntimeError("unexpected PV claimant")
        request(
            "/api/v1/persistentvolumes/" + name,
            "PATCH",
            {"spec": {"persistentVolumeReclaimPolicy": "Retain"}},
        )
    for name in plan["copyJobs"]:
        job = request(job_prefix + name)
        if job:
            request(
                job_prefix + name,
                "DELETE",
                {
                    "preconditions": {"uid": job["metadata"]["uid"]},
                    "propagationPolicy": "Foreground",
                },
            )
            wait_deleted(job_prefix + name)
    for path, claim in [(source_path, source), (target_path, target)]:
        if claim:
            request(
                path, "DELETE", {"preconditions": {"uid": claim["metadata"]["uid"]}}
            )
            wait_deleted(path)
    request(
        "/api/v1/persistentvolumes/" + plan["targetPV"],
        "PATCH",
        {
            "spec": {
                "claimRef": {
                    "apiVersion": "v1",
                    "kind": "PersistentVolumeClaim",
                    "namespace": plan["namespace"],
                    "name": plan["name"],
                    "uid": None,
                    "resourceVersion": None,
                }
            }
        },
    )
    replacement = plan["replacement"]
    if plan.get("cluster"):
        cluster = request(
            "/apis/postgresql.cnpg.io/v1/namespaces/"
            + plan["namespace"]
            + "/clusters/"
            + plan["cluster"]
        )
        if (
            cluster["metadata"]["annotations"].get("cnpg.io/reconciliationLoop")
            != "disabled"
        ):
            raise RuntimeError("cluster reconciliation must remain disabled")
        replacement["metadata"]["ownerReferences"] = [
            {
                "apiVersion": "postgresql.cnpg.io/v1",
                "kind": "Cluster",
                "name": plan["cluster"],
                "uid": cluster["metadata"]["uid"],
                "controller": True,
                "blockOwnerDeletion": True,
            }
        ]
    request(prefix + "/persistentvolumeclaims", "POST", replacement)
    for _ in range(120):
        current = request(source_path)
        if (
            current
            and current.get("status", {}).get("phase") == "Bound"
            and current["spec"]["volumeName"] == plan["targetPV"]
        ):
            print("Verified replacement bound; original disk retained", flush=True)
            return
        time.sleep(3)
    raise RuntimeError("replacement did not bind; writers must remain stopped")


if __name__ == "__main__":
    main()
