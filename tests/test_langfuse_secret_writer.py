import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location(
    "langfuse_writer", ROOT / "scripts/identity/create-langfuse-oidc-app.py"
)
writer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(writer)


class Bao:
    def __init__(self, value=None, version=0):
        self.value, self.version, self.writes = value, version, []

    def request(self, method, path, body=None):
        if method == "GET":
            if self.value is None:
                return None
            return {
                "data": {
                    "data": {"value": self.value},
                    "metadata": {"version": self.version},
                }
            }
        assert body["options"]["cas"] == self.version
        self.writes.append((path, body))
        self.value = body["data"]["value"]
        self.version += 1
        return {"data": {"version": self.version}}


def test_writer_uses_openbao_and_cas_for_rotation():
    bao = Bao("previous", 3)
    writer.store("langfuse/app/langfuse-zitadel-client-secret", "replacement", bao)
    assert bao.writes == [
        (
            "kv/data/langfuse/app/langfuse-zitadel-client-secret",
            {
                "options": {"cas": 3},
                "data": {"value": "replacement"},
            },
        )
    ]


def test_writer_is_idempotent_and_rejects_unreviewed_destinations():
    bao = Bao("same", 3)
    writer.store("langfuse/app/langfuse-zitadel-client-id", "same", bao)
    assert bao.writes == []
    with pytest.raises(ValueError):
        writer.store("other/app/credential", "secret", bao)
    assert bao.writes == []


def test_storage_conflict_is_not_retried_or_overwritten():
    class Conflict(Bao):
        def request(self, method, path, body=None):
            if method == "POST":
                self.writes.append((path, body))
                raise writer.MigrationError("OpenBao POST failed (HTTP 400)")
            return super().request(method, path, body)

    bao = Conflict("previous", 3)
    with pytest.raises(writer.MigrationError):
        writer.store("langfuse/app/langfuse-zitadel-client-secret", "replacement", bao)
    assert len(bao.writes) == 1
    assert bao.value == "previous"


def test_missing_openbao_access_stops_before_identity_changes(monkeypatch):
    monkeypatch.setenv("ZITADEL_PAT", "synthetic")
    monkeypatch.delenv("BAO_TOKEN", raising=False)
    calls = []
    monkeypatch.setattr(writer.Client, "expect", lambda *args: calls.append(args))
    with pytest.raises(ValueError, match="BAO_TOKEN"):
        writer.main()
    assert calls == []
