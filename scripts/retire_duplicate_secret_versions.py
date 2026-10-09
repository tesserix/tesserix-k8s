#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["cryptography>=46,<47"]
# ///
import argparse
import base64
import hmac
import json
import os
import subprocess
import urllib.error
import urllib.request
from collections.abc import Callable
from pathlib import Path
from typing import Any, Protocol


class Client(Protocol):
    def metadata(self, name: str) -> dict[str, Any]: ...
    def access(self, name: str) -> bytes: ...
    def destroy(self, name: str, etag: str) -> dict[str, Any]: ...


def retire(
    client: Client,
    candidate: dict[str, Any],
    verify_recovery: Callable[[str, bytes], None],
) -> dict[str, Any]:
    expected_secret = candidate["secret"]
    expected_old = candidate["version"]
    expected_latest = candidate["retained"]
    secret = client.metadata(expected_secret["name"])
    old = client.metadata(expected_old["name"])
    latest = client.metadata(secret["name"] + "/versions/latest")
    number = old["name"].rsplit("/", 1)[1]
    prefix = secret["name"] + "/versions/"
    if not old["name"].startswith(prefix) or not latest["name"].startswith(prefix):
        raise ValueError("Version does not belong to the reviewed secret")
    if not number.isdecimal() or int(number) >= int(latest["name"].rsplit("/", 1)[1]):
        raise ValueError("Current or newer version is protected")
    if number in {str(v) for v in secret.get("versionAliases", {}).values()}:
        raise ValueError("Aliased version is protected")
    if number in {str(v) for v in candidate["protected_versions"]}:
        raise ValueError("Pinned or owned version is protected")
    if secret.get("versionDestroyTtl") not in (None, "0s"):
        raise ValueError("Delayed destruction requires a separate reviewed plan")
    if secret["etag"] != expected_secret["etag"] or old["etag"] != expected_old["etag"]:
        raise ValueError("Metadata changed since review")
    if (
        latest["name"] != expected_latest["name"]
        or latest["etag"] != expected_latest["etag"]
    ):
        raise ValueError("Retained version changed since review")
    if old["state"] != "ENABLED" or latest["state"] != "ENABLED":
        raise ValueError("Both compared versions must remain enabled")
    old_value = client.access(old["name"])
    latest_value = client.access(latest["name"])
    if not old_value or not hmac.compare_digest(old_value, latest_value):
        raise ValueError("Older value differs from retained value")
    verify_recovery(old["name"], old_value)
    result = client.destroy(old["name"], old["etag"])
    if result["name"] != old["name"] or result["state"] != "DESTROYED":
        raise ValueError("Destruction not confirmed; inspect before continuing")
    return {
        "name": result["name"],
        "state": result["state"],
        "retained": latest["name"],
    }


class GcpClient:
    def __init__(self, token: str):
        self.token = token

    def request(self, name: str, body: dict[str, str] | None = None) -> dict[str, Any]:
        request = urllib.request.Request(
            "https://secretmanager.googleapis.com/v1/" + name,
            data=None if body is None else json.dumps(body).encode(),
            headers={
                "Authorization": "Bearer " + self.token,
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                result: dict[str, Any] = json.load(response)
                return result
        except urllib.error.HTTPError as error:
            raise ValueError(f"Secret Manager returned HTTP {error.code}") from None

    def metadata(self, name: str) -> dict[str, Any]:
        return self.request(name)

    def access(self, name: str) -> bytes:
        response = self.request(name + ":access")
        if response["name"] != name:
            raise ValueError("Access resolved to an unexpected version")
        return base64.b64decode(response["payload"]["data"], validate=True)

    def destroy(self, name: str, etag: str) -> dict[str, Any]:
        return self.request(name + ":destroy", {"etag": etag})


def main() -> None:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    parser = argparse.ArgumentParser(
        description="Retire approved, unreferenced exact duplicate versions"
    )
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("--execute", action="store_true", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    plan = json.loads(args.plan.read_text())
    config = json.loads(
        subprocess.check_output(
            ["gcloud", "config", "list", "--format=json(core.account,core.project)"],
            text=True,
        )
    )["core"]
    if config != {"account": plan["account"], "project": plan["project"]}:
        raise ValueError("Active cloud account/project differs from reviewed scope")
    for path in (args.archive, args.key):
        if path.stat().st_mode & 0o077:
            raise ValueError("Recovery files must be private")
    sealed = args.archive.read_bytes()
    recovery = json.loads(
        AESGCM(args.key.read_bytes()).decrypt(
            sealed[:12], sealed[12:], b"tesserix-secret-version-recovery-v1"
        )
    )

    def verify(name: str, value: bytes) -> None:
        restored = base64.b64decode(recovery[name]["payload"], validate=True)
        if not hmac.compare_digest(restored, value):
            raise ValueError("Recovery copy failed equality verification")

    token = subprocess.check_output(
        ["gcloud", "auth", "print-access-token"], text=True
    ).strip()
    client = GcpClient(token)
    with args.record.open("x") as record:
        for candidate in plan["candidates"]:
            if not candidate["secret"]["name"].startswith(
                plan["project_resource"] + "/secrets/"
            ):
                raise ValueError("Candidate is outside the reviewed project")
            result = retire(client, candidate, verify)
            record.write(json.dumps(result) + "\n")
            record.flush()
            os.fsync(record.fileno())
            print(result["name"].split("/secrets/", 1)[1], result["state"], flush=True)


if __name__ == "__main__":
    main()
