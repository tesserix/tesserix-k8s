import base64
import importlib.util
import json
import subprocess
from pathlib import Path

import pytest

MODULE = (
    Path(__file__).parents[1] / "charts/thirdparty/openbao/files/recovery_record.py"
)
spec = importlib.util.spec_from_file_location("recovery_record", MODULE)
record = importlib.util.module_from_spec(spec)
spec.loader.exec_module(record)

PAYLOAD = json.dumps(
    {
        "recovery_keys_base64": [
            base64.b64encode(bytes([i]) * 32).decode() for i in range(1, 6)
        ],
        "root_token": "synthetic-root",
    }
).encode()
URI = "gs://isolated-bootstrap/bootstrap/init.json.kms"
KEY = (
    "projects/test-project/locations/asia-south1/keyRings/recovery/cryptoKeys/bootstrap"
)


class Cloud:
    def __init__(self, existing=None, denied=False):
        self.stored = existing
        self.denied = denied
        self.calls = []

    def __call__(self, args, **kwargs):
        self.calls.append((args, kwargs.get("input")))
        if args[1:3] == ["storage", "cat"]:
            if self.denied:
                return subprocess.CompletedProcess(
                    args, 1, b"", b"403 credential-must-not-leak"
                )
            return subprocess.CompletedProcess(
                args,
                0 if self.stored else 1,
                self.stored or b"",
                b"404 not found" if not self.stored else b"",
            )
        if args[1:3] == ["kms", "encrypt"]:
            return subprocess.CompletedProcess(
                args, 0, b"cipher:" + kwargs["input"], b""
            )
        if args[1:3] == ["kms", "decrypt"]:
            assert kwargs["input"].startswith(b"cipher:")
            return subprocess.CompletedProcess(args, 0, kwargs["input"][7:], b"")
        assert args[1:3] == ["storage", "cp"]
        assert "--if-generation-match=0" in args
        assert self.stored is None
        filename = Path(args[3])
        assert filename.stat().st_mode & 0o777 == 0o600
        self.stored = filename.read_bytes()
        return subprocess.CompletedProcess(args, 0, b"", b"")


def test_roundtrip_is_encrypted_cas_guarded_and_payload_absent_from_argv():
    cloud = Cloud()
    client = record.RecoveryRecord(URI, KEY, runner=cloud)
    client.store(PAYLOAD)
    assert client.load() == PAYLOAD
    assert cloud.stored != PAYLOAD
    assert all("synthetic-root" not in " ".join(args) for args, _ in cloud.calls)
    assert not any("secrets" in args for args, _ in cloud.calls)


def test_identical_retry_does_not_write_or_encrypt_again():
    cloud = Cloud(b"cipher:" + PAYLOAD)
    record.RecoveryRecord(URI, KEY, runner=cloud).store(PAYLOAD)
    assert not any(args[2] in ["cp", "encrypt"] for args, _ in cloud.calls)


def test_different_existing_record_is_never_overwritten():
    cloud = Cloud(b"cipher:" + PAYLOAD)
    with pytest.raises(record.RecoveryRecordError, match="differs"):
        record.RecoveryRecord(URI, KEY, runner=cloud).store(
            PAYLOAD.replace(b"synthetic-root", b"another-root")
        )
    assert cloud.stored == b"cipher:" + PAYLOAD


def test_permission_failure_is_not_treated_as_missing_and_is_redacted():
    cloud = Cloud(denied=True)
    with pytest.raises(record.RecoveryRecordError) as error:
        record.RecoveryRecord(URI, KEY, runner=cloud).store(PAYLOAD)
    assert "credential-must-not-leak" not in str(error.value)
    assert len(cloud.calls) == 1


@pytest.mark.parametrize(
    "payload",
    [
        b"{}",
        b"not-json",
        b"x" * 65537,
        json.dumps({"recovery_keys_base64": ["bad"] * 5}).encode(),
    ],
)
def test_invalid_recovery_material_never_reaches_cloud(payload):
    cloud = Cloud()
    with pytest.raises(record.RecoveryRecordError):
        record.RecoveryRecord(URI, KEY, runner=cloud).store(payload)
    assert not cloud.calls


@pytest.mark.parametrize("same", [True, False])
def test_creation_race_verifies_winner_without_overwriting(same):
    class RacingCloud(Cloud):
        def __call__(self, args, **kwargs):
            if args[1:3] == ["storage", "cp"]:
                self.stored = b"cipher:" + (
                    PAYLOAD
                    if same
                    else PAYLOAD.replace(b"synthetic-root", b"different-root")
                )
                return subprocess.CompletedProcess(
                    args, 1, b"", b"412 generation mismatch"
                )
            return super().__call__(args, **kwargs)

    cloud = RacingCloud()
    client = record.RecoveryRecord(URI, KEY, runner=cloud)
    if same:
        client.store(PAYLOAD)
        assert client.load() == PAYLOAD
    else:
        with pytest.raises(record.RecoveryRecordError, match="differs"):
            client.store(PAYLOAD)
        assert cloud.stored.endswith(b'different-root"}')


def test_transport_errors_do_not_expose_credentials():
    def fail(args, **kwargs):
        raise subprocess.TimeoutExpired(args, 120, output=b"credential-must-not-leak")

    with pytest.raises(record.RecoveryRecordError) as error:
        record.RecoveryRecord(URI, KEY, runner=fail).store(PAYLOAD)
    assert "credential-must-not-leak" not in str(error.value)
