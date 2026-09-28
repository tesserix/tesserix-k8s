"""Immutable, independently readable, KMS-encrypted OpenBao recovery material."""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


class RecoveryRecordError(RuntimeError):
    pass


def validate(payload: bytes) -> None:
    try:
        if not 0 < len(payload) <= 65536:
            raise ValueError
        value = json.loads(payload)
        shares = value["recovery_keys_base64"]
        if len(shares) != 5 or len(set(shares)) != 5:
            raise ValueError
        if any(len(base64.b64decode(s, validate=True)) < 16 for s in shares):
            raise ValueError
    except (ValueError, TypeError, KeyError):
        raise RecoveryRecordError("Invalid recovery record; details withheld") from None


class RecoveryRecord:
    def __init__(self, uri: str, key: str, *, runner=subprocess.run):
        if not re.fullmatch(
            r"gs://[a-z0-9][a-z0-9._-]+/bootstrap/[A-Za-z0-9._/-]+", uri
        ):
            raise RecoveryRecordError("Invalid recovery object URI")
        match = re.fullmatch(
            r"projects/([^/]+)/locations/([^/]+)/keyRings/([^/]+)/cryptoKeys/([^/]+)",
            key,
        )
        if not match:
            raise RecoveryRecordError("Invalid KMS key resource")
        project, location, ring, name = match.groups()
        self.uri = uri
        self.kms = [
            f"--project={project}",
            f"--location={location}",
            f"--keyring={ring}",
            f"--key={name}",
        ]
        self.runner = runner

    def call(self, args: list[str], payload: bytes | None = None):
        try:
            return self.runner(
                ["gcloud", *args], input=payload, capture_output=True, timeout=120
            )
        except (OSError, subprocess.SubprocessError):
            raise RecoveryRecordError(
                "Recovery storage unavailable; details withheld"
            ) from None

    def crypt(self, operation: str, payload: bytes) -> bytes:
        source, target = (
            ("plaintext", "ciphertext")
            if operation == "encrypt"
            else ("ciphertext", "plaintext")
        )
        result = self.call(
            ["kms", operation, *self.kms, f"--{source}-file=-", f"--{target}-file=-"],
            payload,
        )
        if result.returncode or not result.stdout:
            raise RecoveryRecordError("Recovery KMS operation failed; details withheld")
        return result.stdout

    def load(self) -> bytes | None:
        result = self.call(["storage", "cat", self.uri])
        if result.returncode:
            if (
                b"404" in result.stderr
                or b"not found" in result.stderr.lower()
                or result.stderr.strip()
                == (
                    b"ERROR: (gcloud.storage.cat) The following URLs matched no objects or files:\n"
                    + self.uri.encode()
                )
            ):
                return None
            raise RecoveryRecordError("Recovery object read failed; details withheld")
        payload = self.crypt("decrypt", result.stdout)
        validate(payload)
        return payload

    def store(self, payload: bytes) -> None:
        validate(payload)
        existing = self.load()
        if existing is not None:
            self.compare(existing, payload)
            return
        cipher = self.crypt("encrypt", payload)
        with tempfile.TemporaryDirectory(prefix="bao-recovery-") as directory:
            filename = Path(directory) / "record.kms"
            with filename.open("xb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(cipher)
            result = self.call(
                [
                    "storage",
                    "cp",
                    str(filename),
                    self.uri,
                    "--if-generation-match=0",
                    "--quiet",
                ]
            )
        if result.returncode:
            existing = self.load()
            if existing is None:
                raise RecoveryRecordError(
                    "Recovery object creation failed; details withheld"
                )
            self.compare(existing, payload)
            return
        existing = self.load()
        if existing is None:
            raise RecoveryRecordError("Recovery object verification failed")
        self.compare(existing, payload)

    @staticmethod
    def compare(existing: bytes, expected: bytes) -> None:
        if not hmac.compare_digest(
            hashlib.sha256(existing).digest(), hashlib.sha256(expected).digest()
        ):
            raise RecoveryRecordError(
                "Existing recovery record differs; refusing replacement"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["store", "load", "inspect", "run"])
    parser.add_argument("filename", type=Path, nargs="?")
    args = parser.parse_args()
    try:
        client = RecoveryRecord(
            os.environ["RECOVERY_OBJECT_URI"], os.environ["RECOVERY_KMS_KEY"]
        )
        if args.operation == "inspect":
            if client.load() is None:
                print("Recovery record absent")
                return 3
            print("Recovery record present")
            return 0
        if args.filename is None:
            raise RecoveryRecordError("A filename is required")
        if args.operation == "run":
            staging = Path(os.environ.get("RECOVERY_STAGING_DIR", "/recovery"))
            with (staging / ".bootstrap.lock").open("a+") as lock:
                os.fchmod(lock.fileno(), 0o600)
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return subprocess.run(
                    ["/bin/bash", str(args.filename)],
                    pass_fds=(lock.fileno(),),
                    check=False,
                ).returncode
        if args.operation == "store":
            descriptor = os.open(args.filename, os.O_RDWR | os.O_NOFOLLOW)
            with os.fdopen(descriptor, "r+b") as stream:
                os.fchmod(stream.fileno(), 0o600)
                payload = stream.read(65537)
                os.fsync(stream.fileno())
            directory = os.open(args.filename.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            client.store(payload)
        else:
            payload = client.load()
            if payload is None:
                raise RecoveryRecordError("Recovery record is missing")
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(
                    dir=args.filename.parent, delete=False
                ) as stream:
                    temporary = Path(stream.name)
                    stream.write(payload)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, args.filename)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        print("Recovery record verified")
        return 0
    except (RecoveryRecordError, OSError, KeyError):
        print("Recovery record operation failed; details withheld")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
