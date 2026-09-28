"""Immutable, independently readable, KMS-encrypted OpenBao recovery material."""

from __future__ import annotations

import argparse
import base64
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
            if b"404" in result.stderr or b"not found" in result.stderr.lower():
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
    parser.add_argument("operation", choices=["store", "load"])
    parser.add_argument("filename", type=Path)
    args = parser.parse_args()
    try:
        client = RecoveryRecord(
            os.environ["RECOVERY_OBJECT_URI"], os.environ["RECOVERY_KMS_KEY"]
        )
        if args.operation == "store":
            client.store(args.filename.read_bytes())
        else:
            payload = client.load()
            if payload is None:
                raise RecoveryRecordError("Recovery record is missing")
            with args.filename.open("wb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(payload)
        print("Recovery record verified")
        return 0
    except (RecoveryRecordError, OSError, KeyError):
        print("Recovery record operation failed; details withheld")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
