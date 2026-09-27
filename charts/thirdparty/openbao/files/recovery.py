"""Verified, generation-safe OpenBao snapshots and isolated restore checks."""

import argparse
import contextlib
import datetime
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


class RecoveryError(Exception):
    pass


def select_backups(
    existing: list[dict[str, Any]], candidate: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if candidate.get("verified") is not True or any(
        b.get("verified") is not True for b in existing
    ):
        raise RecoveryError("Only restore-verified snapshots can enter the catalog")
    by_id = {b["id"]: b for b in existing}
    if candidate["id"] in by_id and by_id[candidate["id"]] != candidate:
        raise RecoveryError("Immutable backup identity changed")
    by_id[candidate["id"]] = candidate
    ordered = sorted(
        by_id.values(),
        key=lambda b: (
            datetime.datetime.fromisoformat(b["created"].replace("Z", "+00:00")),
            b["id"],
        ),
        reverse=True,
    )
    return ordered[:3], ordered[3:]


MAX_BYTES = 256 * 1024 * 1024
MARKER = "kv/data/platform/backup-verification"
LOCAL = "http://127.0.0.1:18230"
ID_PATTERN = re.compile(r"[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}")


def validate_snapshot(filename: Path) -> None:
    expected = {"meta.json", "state.bin", "SHA256SUMS", "SHA256SUMS.sealed"}
    digests: dict[str, str] = {}
    sums = ""
    total = 0
    try:
        with tarfile.open(filename, "r:gz") as archive:
            for member in archive:
                if (
                    member.name not in expected
                    or member.name in digests
                    or not member.isfile()
                ):
                    raise RecoveryError("Invalid snapshot members")
                total += member.size
                if total > MAX_BYTES * 4:
                    raise RecoveryError("Snapshot exceeds restore storage budget")
                stream = archive.extractfile(member)
                if stream is None:
                    raise RecoveryError("Missing snapshot member")
                digest = hashlib.sha256()
                chunks = []
                while chunk := stream.read(65536):
                    digest.update(chunk)
                    if member.name == "SHA256SUMS":
                        if member.size > 8192:
                            raise RecoveryError("Invalid snapshot checksums")
                        chunks.append(chunk)
                digests[member.name] = digest.hexdigest()
                if chunks:
                    sums = b"".join(chunks).decode("ascii")
        if set(digests) != expected:
            raise RecoveryError("Incomplete snapshot")
        verified = set()
        for line in sums.splitlines():
            checksum, name = line.split()
            if name not in ("meta.json", "state.bin") or not hmac.compare_digest(
                checksum, digests[name]
            ):
                raise RecoveryError("Snapshot internal checksum mismatch")
            verified.add(name)
        if verified != {"meta.json", "state.bin"}:
            raise RecoveryError("Missing internal checksums")
    except (tarfile.TarError, OSError, ValueError, UnicodeError, EOFError) as exc:
        raise RecoveryError("Unreadable snapshot") from exc


def validate_catalog(value: dict[str, Any]) -> None:
    if (
        value.get("schema") != 1
        or not isinstance(value.get("backups"), list)
        or len(value["backups"]) > 3
    ):
        raise RecoveryError("Invalid backup catalog")
    pending = value.get("pending_deletions", [])
    if not isinstance(pending, list) or len(pending) > 3:
        raise RecoveryError("Invalid pending deletions")
    for old in pending:
        validate_catalog({"schema": 1, "backups": [old]})
    if {b["id"] for b in pending} & {b["id"] for b in value["backups"]}:
        raise RecoveryError("Retained backup cannot be pending deletion")
    ids = set()
    for backup in value["backups"]:
        identifier = backup.get("id", "")
        if not ID_PATTERN.fullmatch(identifier) or identifier in ids:
            raise RecoveryError("Invalid backup identifier")
        ids.add(identifier)
        if (
            backup.get("object") != f"snapshots/{identifier}.snap"
            or backup.get("verified") is not True
        ):
            raise RecoveryError("Invalid backup object")
        if not re.fullmatch(
            r"[0-9]+", backup.get("generation", "")
        ) or not re.fullmatch(r"[a-f0-9]{64}", backup.get("sha256", "")):
            raise RecoveryError("Invalid immutable snapshot metadata")
        if (
            not isinstance(backup.get("marker_version"), int)
            or backup["marker_version"] < 1
        ):
            raise RecoveryError("Invalid verification version")
        if not re.fullmatch(r"[a-f0-9]{64}", backup.get("marker_sha256", "")):
            raise RecoveryError("Invalid verification checksum")
        datetime.datetime.fromisoformat(backup["created"].replace("Z", "+00:00"))


def restore_config(
    directory: Path, project: str, region: str, ring: str, key: str
) -> dict[str, Any]:
    return {
        "disable_mlock": True,
        "api_addr": LOCAL,
        "cluster_addr": "https://127.0.0.1:18231",
        "listener": {
            "tcp": {
                "address": "127.0.0.1:18230",
                "cluster_address": "127.0.0.1:18231",
                "tls_disable": True,
            }
        },
        "storage": {
            "raft": {"path": str(directory / "raft"), "node_id": "isolated-verifier"}
        },
        "seal": {
            "gcpckms": {
                "project": project,
                "region": region,
                "key_ring": ring,
                "crypto_key": key,
            }
        },
    }


class Http:
    def __init__(self) -> None:
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(
        self,
        method: str,
        url: str,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, bytes]:
        request = urllib.request.Request(
            url, data=data, method=method, headers=headers or {}
        )
        for attempt in range(4):
            try:
                with self.opener.open(request, timeout=90) as response:
                    body = response.read(MAX_BYTES + 1)
                    if len(body) > MAX_BYTES:
                        raise RecoveryError("Response exceeds snapshot budget")
                    return response.status, body
            except urllib.error.HTTPError as exc:
                if exc.code in (404, 409, 412):
                    return exc.code, b""
                if exc.code not in (429, 500, 502, 503, 504) or attempt == 3:
                    raise RecoveryError(f"HTTP operation failed ({exc.code})") from None
            except (urllib.error.URLError, TimeoutError):
                if attempt == 3:
                    raise RecoveryError("HTTP operation timed out") from None
            time.sleep((2**attempt) + secrets.randbelow(1000) / 1000)
        raise RecoveryError("HTTP retries exhausted")


class Bao:
    def __init__(self, address: str, token: str = "") -> None:
        self.address = address
        self.token = token
        self.http = Http()

    def call(
        self, method: str, path: str, body: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        status, raw = self.http.request(
            method,
            self.address + "/v1/" + path,
            json.dumps(body).encode() if body is not None else None,
            {"X-Vault-Token": self.token, "Content-Type": "application/json"},
        )
        if status not in (200, 204):
            raise RecoveryError(f"OpenBao operation failed ({status})")
        value: dict[str, Any] = json.loads(raw) if raw else {}
        return value

    def login(self, role: str) -> "Bao":
        jwt = (
            Path("/var/run/secrets/kubernetes.io/serviceaccount/token")
            .read_text()
            .strip()
        )
        result = self.call("POST", "auth/kubernetes/login", {"role": role, "jwt": jwt})
        return Bao(self.address, result["auth"]["client_token"])

    def revoke(self) -> None:
        self.call("POST", "auth/token/revoke-self", {})


class Storage:
    def __init__(self, bucket: str, key: str) -> None:
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{2,221}[a-z0-9]", bucket):
            raise RecoveryError("Invalid recovery bucket")
        self.bucket, self.key = bucket, key
        self.http = Http()

    def call(
        self,
        method: str,
        name: str,
        *,
        generation: str | None = None,
        upload: bytes | None = None,
        media: bool = False,
        list_page: str | None = None,
    ) -> tuple[int, bytes]:
        token = subprocess.check_output(
            ["gcloud", "auth", "print-access-token"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=30,
        ).strip()
        params = {}
        if upload is not None:
            endpoint = (
                f"https://storage.googleapis.com/upload/storage/v1/b/{self.bucket}/o"
            )
            params.update({"uploadType": "media", "name": name, "kmsKeyName": self.key})
        else:
            endpoint = f"https://storage.googleapis.com/storage/v1/b/{self.bucket}/o/{urllib.parse.quote(name, safe='')}"
        if list_page is not None:
            endpoint = f"https://storage.googleapis.com/storage/v1/b/{self.bucket}/o"
            params.update(
                {"prefix": "snapshots/", "maxResults": "100", "pageToken": list_page}
            )
        if generation is not None:
            params[
                "ifGenerationMatch" if method in ("POST", "DELETE") else "generation"
            ] = generation
        if media:
            params["alt"] = "media"
        return self.http.request(
            method,
            endpoint + "?" + urllib.parse.urlencode(params),
            upload,
            {
                "Authorization": "Bearer " + token,
                "Content-Type": "application/octet-stream",
            },
        )

    def metadata(self, name: str) -> dict[str, Any] | None:
        status, raw = self.call("GET", name)
        if status == 404:
            return None
        if status != 200:
            raise RecoveryError("Object metadata unavailable")
        value: dict[str, Any] = json.loads(raw)
        if not str(value.get("kmsKeyName", "")).startswith(
            self.key + "/cryptoKeyVersions/"
        ):
            raise RecoveryError("Object is not encrypted with the required CMEK")
        return value

    def catalog(self) -> tuple[dict[str, Any], str]:
        meta = self.metadata("catalog.json")
        if meta is None:
            return {"schema": 1, "backups": []}, "0"
        status, raw = self.call(
            "GET", "catalog.json", generation=meta["generation"], media=True
        )
        if status != 200:
            raise RecoveryError("Catalog generation disappeared")
        value = json.loads(raw)
        validate_catalog(value)
        return value, meta["generation"]

    def download(self, backup: dict[str, Any], destination: Path) -> None:
        meta = self.metadata(backup["object"])
        if (
            meta is None
            or meta["generation"] != backup["generation"]
            or int(meta["size"]) > MAX_BYTES
        ):
            raise RecoveryError("Snapshot generation unavailable")
        status, raw = self.call(
            "GET", backup["object"], generation=backup["generation"], media=True
        )
        if status != 200 or not hmac.compare_digest(
            hashlib.sha256(raw).hexdigest(), backup["sha256"]
        ):
            raise RecoveryError("Downloaded snapshot checksum mismatch")
        destination.write_bytes(raw)
        destination.chmod(0o600)
        validate_snapshot(destination)

    def prune(self, removed: list[dict[str, Any]]) -> None:
        for old in removed:
            status, _ = self.call("DELETE", old["object"], generation=old["generation"])
            if status not in (204, 404):
                raise RecoveryError(
                    "Verified catalog committed but pruning needs retry"
                )

    def prune_orphans(self) -> None:
        catalog, _ = self.catalog()
        retained = catalog["backups"]
        if len(retained) < 3:
            return
        cutoff = min(
            datetime.datetime.fromisoformat(b["created"].replace("Z", "+00:00"))
            for b in retained
        )
        protected = {b["object"] for b in retained}
        page = ""
        for _ in range(100):
            status, raw = self.call("GET", "", list_page=page)
            if status != 200:
                raise RecoveryError("Unable to enumerate interrupted uploads")
            listing = json.loads(raw)
            for obj in listing.get("items", []):
                name = obj.get("name", "")
                if (
                    not re.fullmatch(
                        r"snapshots/[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}\.snap", name
                    )
                    or name in protected
                ):
                    continue
                created = datetime.datetime.fromisoformat(
                    obj["timeCreated"].replace("Z", "+00:00")
                )
                if created < cutoff:
                    self.prune([{"object": name, "generation": obj["generation"]}])
            page = listing.get("nextPageToken", "")
            if not page:
                return
        raise RecoveryError("Interrupted upload cleanup exceeded page budget")

    def publish(self, candidate: dict[str, Any]) -> None:
        for _ in range(5):
            catalog, generation = self.catalog()
            retained, removed = select_backups(catalog["backups"], candidate)
            if candidate not in retained:
                raise RecoveryError("Candidate superseded by newer verified backups")
            self.prune(catalog.get("pending_deletions", []))
            updated = {"schema": 1, "backups": retained, "pending_deletions": removed}
            validate_catalog(updated)
            status, _ = self.call(
                "POST",
                "catalog.json",
                generation=generation,
                upload=json.dumps(updated, sort_keys=True).encode(),
            )
            if status == 412:
                continue
            if status not in (200, 201):
                raise RecoveryError("Catalog commit failed; no backups pruned")
            self.prune(removed)
            return
        raise RecoveryError("Concurrent catalog update; no backups pruned")


def isolated_restore(filename: Path, backup: dict[str, Any], directory: Path) -> float:
    validate_snapshot(filename)
    started = time.monotonic()
    (directory / "raft").mkdir(mode=0o700)
    config = restore_config(
        directory,
        os.environ["GCP_PROJECT"],
        os.environ["KMS_REGION"],
        os.environ["KMS_RING"],
        os.environ["UNSEAL_KEY"],
    )
    config_file = directory / "server.json"
    config_file.write_text(json.dumps(config))
    process: subprocess.Popen[bytes] | None = None
    verifier: Bao | None = None
    with (directory / "server.log").open("wb") as log:

        def start() -> subprocess.Popen[bytes]:
            return subprocess.Popen(
                [
                    os.environ.get("BAO_BINARY", "/tools/bao"),
                    "server",
                    "-config=" + str(config_file),
                ],
                stdout=log,
                stderr=log,
            )

        def ready(unsealed: bool = False) -> None:
            for _ in range(90):
                if process is None or process.poll() is not None:
                    raise RecoveryError("Isolated restore server stopped")
                try:
                    status = Bao(LOCAL).call("GET", "sys/seal-status")
                    if not unsealed or (status["initialized"] and not status["sealed"]):
                        return
                except RecoveryError:
                    pass
                time.sleep(1)
            raise RecoveryError("Isolated restore did not become ready")

        try:
            process = start()
            ready()
            initial = Bao(LOCAL).call(
                "POST", "sys/init", {"recovery_shares": 1, "recovery_threshold": 1}
            )
            local_admin = Bao(LOCAL, initial["root_token"])
            del initial
            ready(unsealed=True)
            status, _ = local_admin.http.request(
                "POST",
                LOCAL + "/v1/sys/storage/raft/snapshot-force",
                filename.read_bytes(),
                {
                    "X-Vault-Token": local_admin.token,
                    "Content-Type": "application/octet-stream",
                },
            )
            del local_admin
            if status not in (200, 204):
                raise RecoveryError("Isolated snapshot restore rejected")
            process.terminate()
            process.wait(timeout=30)
            process = start()
            ready(unsealed=True)
            verifier = Bao(LOCAL).login("snapshot-verify")
            marker = verifier.call(
                "GET", MARKER + "?version=" + str(backup["marker_version"])
            )["data"]
            digest = hashlib.sha256(marker["data"]["nonce"].encode()).hexdigest()
            if marker["metadata"]["version"] != backup[
                "marker_version"
            ] or not hmac.compare_digest(digest, backup["marker_sha256"]):
                raise RecoveryError("Restored marker/version mismatch")
            return round(time.monotonic() - started, 3)
        finally:
            if verifier is not None:
                with contextlib.suppress(RecoveryError):
                    verifier.revoke()
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)


def execute(mode: str, backup_id: str | None = None) -> dict[str, Any]:
    store = Storage(os.environ["BACKUP_BUCKET"], os.environ["BACKUP_KMS_KEY"])
    with tempfile.TemporaryDirectory(prefix="openbao-recovery-") as temp:
        directory = Path(temp)
        snapshot = directory / "snapshot.snap"
        if mode == "restore-test":
            catalog, _ = store.catalog()
            matches = [
                b
                for b in catalog["backups"]
                if backup_id is None or b["id"] == backup_id
            ]
            if not matches:
                raise RecoveryError("Requested verified backup is unavailable")
            candidate = matches[0]
            store.download(candidate, snapshot)
            seconds = isolated_restore(snapshot, candidate, directory)
            return {
                "operation": mode,
                "backup_id": candidate["id"],
                "result": "PASS",
                "restore_seconds": seconds,
            }
        now = datetime.datetime.now(datetime.timezone.utc)
        identifier = now.strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(6)
        source = Bao(os.environ["BAO_ADDR"]).login("recovery-backup")
        candidate = None
        try:
            nonce = secrets.token_hex(32)
            version = source.call("POST", MARKER, {"data": {"nonce": nonce}})["data"][
                "version"
            ]
            status, raw = source.http.request(
                "GET",
                source.address + "/v1/sys/storage/raft/snapshot",
                headers={"X-Vault-Token": source.token},
            )
            if status != 200 or len(raw) < 4096:
                raise RecoveryError("Snapshot capture incomplete")
            snapshot.write_bytes(raw)
            validate_snapshot(snapshot)
            name = f"snapshots/{identifier}.snap"
            status, _ = store.call("POST", name, generation="0", upload=raw)
            if status not in (200, 201):
                raise RecoveryError("Snapshot upload was not created")
            meta = store.metadata(name)
            if meta is None:
                raise RecoveryError("Uploaded snapshot unavailable")
            candidate = {
                "id": identifier,
                "object": name,
                "generation": meta["generation"],
                "created": meta["timeCreated"],
                "bytes": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest(),
                "marker_version": version,
                "marker_sha256": hashlib.sha256(nonce.encode()).hexdigest(),
                "verified": False,
                "openbao_version": os.environ["BAO_VERSION"],
                "kms_key": store.key,
            }
            del raw, nonce
            store.download(candidate, snapshot)
            candidate["restore_seconds"] = isolated_restore(
                snapshot, candidate, directory
            )
            candidate["verified"] = True
            store.publish(candidate)
            store.prune_orphans()
            return {
                "operation": mode,
                "backup_id": identifier,
                "result": "PASS",
                "restore_seconds": candidate["restore_seconds"],
                "retained": len(store.catalog()[0]["backups"]),
            }
        finally:
            with contextlib.suppress(RecoveryError):
                source.revoke()
            if candidate is not None:
                catalog, _ = store.catalog()
                if candidate["id"] not in {b["id"] for b in catalog["backups"]}:
                    store.call(
                        "DELETE",
                        candidate["object"],
                        generation=candidate["generation"],
                    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("backup", "restore-test"))
    parser.add_argument("--backup-id")
    args = parser.parse_args()
    try:
        result = execute(args.operation, args.backup_id)
        line = json.dumps(result, sort_keys=True)
        print(line, flush=True)
        Path("/dev/termination-log").write_text(line)
        return 0
    except (
        RecoveryError,
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
    ):
        print(
            json.dumps(
                {
                    "operation": args.operation,
                    "result": "FAIL",
                    "error": "Recovery verification failed; no production restore attempted; inspect job status",
                }
            ),
            flush=True,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
