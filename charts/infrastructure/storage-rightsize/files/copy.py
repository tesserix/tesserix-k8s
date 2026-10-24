import hashlib
import json
import os
import shutil
import ssl
import stat
import subprocess
import time
import urllib.request
from pathlib import Path


def assert_quiescent(pods, claim, own_pod):
    for pod in pods:
        if pod["metadata"]["name"] == own_pod or pod["status"].get("phase") in (
            "Succeeded",
            "Failed",
        ):
            continue
        if any(
            v.get("persistentVolumeClaim", {}).get("claimName") == claim
            for v in pod["spec"].get("volumes", [])
        ):
            raise RuntimeError("another pod still references the source volume")


def entries(root):
    return {
        p.relative_to(root): p
        for p in root.rglob("*")
        if p.relative_to(root).parts[0]
        not in ("lost+found", ".rightsize-verified.json")
    }


def verify(source, target):
    left, right = entries(source), entries(target)
    if left.keys() != right.keys():
        raise RuntimeError("file inventory mismatch")
    count = 0
    for name, a in left.items():
        b = right[name]
        sa, sb = a.lstat(), b.lstat()
        if (sa.st_mode, sa.st_uid, sa.st_gid) != (sb.st_mode, sb.st_uid, sb.st_gid):
            raise RuntimeError("file ownership or mode mismatch")
        if stat.S_ISLNK(sa.st_mode):
            if os.readlink(a) != os.readlink(b):
                raise RuntimeError("symlink mismatch")
        elif stat.S_ISREG(sa.st_mode):
            with a.open("rb") as x, b.open("rb") as y:
                if (
                    hashlib.file_digest(x, "sha256").digest()
                    != hashlib.file_digest(y, "sha256").digest()
                ):
                    raise RuntimeError("file content mismatch")
            count += 1
        elif not stat.S_ISDIR(sa.st_mode):
            raise RuntimeError("unexpected special file on offline database volume")
    return count


def api(path):
    mount = Path("/var/run/secrets/kubernetes.io/serviceaccount")
    token = (mount / "token").read_text().strip()
    request = urllib.request.Request(
        "https://kubernetes.default.svc" + path,
        headers={"Authorization": "Bearer " + token},
    )
    with urllib.request.urlopen(
        request,
        context=ssl.create_default_context(cafile=str(mount / "ca.crt")),
        timeout=30,
    ) as response:
        return json.load(response)


def main():
    namespace, claim = os.environ["NAMESPACE"], os.environ["SOURCE_CLAIM"]
    prefix = "/api/v1/namespaces/" + namespace
    source_claim = api(prefix + "/persistentvolumeclaims/" + claim)
    if source_claim["metadata"]["uid"] != os.environ["SOURCE_UID"]:
        raise RuntimeError("source PVC identity changed; refusing copy")
    for attempt in range(120):
        try:
            assert_quiescent(
                api(prefix + "/pods")["items"], claim, os.environ["POD_NAME"]
            )
            break
        except RuntimeError:
            if attempt == 119:
                raise
            time.sleep(10)
    source, target = Path("/source"), Path("/target")
    if entries(target):
        raise RuntimeError("target is not empty; refusing overwrite")
    bytes_needed = sum(
        p.lstat().st_size
        for p in entries(source).values()
        if p.is_file() and not p.is_symlink()
    )
    if bytes_needed > shutil.disk_usage(target).free * 0.85:
        raise RuntimeError("insufficient target headroom")
    subprocess.run(
        ["cp", "--archive", "--sparse=always", "--", str(source) + "/.", str(target)],
        check=True,
    )
    os.sync()
    count = verify(source, target)
    assert_quiescent(api(prefix + "/pods")["items"], claim, os.environ["POD_NAME"])
    (target / ".rightsize-verified.json").write_text(
        json.dumps(
            {
                "source_uid": source_claim["metadata"]["uid"],
                "files": count,
                "verified": True,
            }
        )
    )
    os.sync()
    print(f"Verified {count} regular files with SHA-256; source preserved", flush=True)


if __name__ == "__main__":
    main()
