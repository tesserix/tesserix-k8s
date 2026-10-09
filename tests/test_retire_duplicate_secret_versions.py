import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from retire_duplicate_secret_versions import retire


class FakeClient:
    def __init__(self):
        self.secret = {"name": "projects/p/secrets/example", "etag": "s1"}
        self.old = {
            "name": "projects/p/secrets/example/versions/1",
            "state": "ENABLED",
            "etag": "v1",
        }
        self.latest = {
            "name": "projects/p/secrets/example/versions/2",
            "state": "ENABLED",
            "etag": "v2",
        }
        self.payloads = {
            self.old["name"]: b"same value",
            self.latest["name"]: b"same value",
        }
        self.destroyed = []

    def metadata(self, name):
        return {
            self.secret["name"]: self.secret,
            self.old["name"]: self.old,
            self.latest["name"]: self.latest,
            self.secret["name"] + "/versions/latest": self.latest,
        }[name]

    def access(self, name):
        return self.payloads[name]

    def destroy(self, name, etag):
        self.destroyed.append((name, etag))
        self.old = self.old | {"state": "DESTROYED"}
        return self.old


def candidate(client):
    return {
        "secret": client.secret.copy(),
        "version": client.old.copy(),
        "retained": client.latest.copy(),
        "protected_versions": [],
    }


def test_destroys_only_after_verified_recovery():
    client = FakeClient()
    archived = []

    def recovery(name, value):
        assert client.destroyed == []
        archived.append((name, value))

    result = retire(client, candidate(client), recovery)
    assert client.destroyed == [(client.old["name"], "v1")]
    assert archived == [(client.old["name"], b"same value")]
    assert result["state"] == "DESTROYED"


@pytest.mark.parametrize(
    "change",
    [
        "latest",
        "alias",
        "pin",
        "different",
        "etag",
        "disabled",
        "retained_changed",
        "secret_changed",
        "delayed",
    ],
)
def test_protects_current_pinned_different_or_changed_versions(change):
    client = FakeClient()
    plan = candidate(client)
    if change == "latest":
        plan["version"] = client.latest.copy()
    elif change == "alias":
        client.secret["versionAliases"] = {"previous": "1"}
    elif change == "pin":
        plan["protected_versions"] = ["1"]
    elif change == "different":
        client.payloads[client.old["name"]] = b"different value"
    elif change == "etag":
        client.old["etag"] = "changed"
    elif change == "disabled":
        client.old["state"] = "DISABLED"
    elif change == "retained_changed":
        client.latest = client.latest | {
            "name": "projects/p/secrets/example/versions/3"
        }
    elif change == "secret_changed":
        client.secret["etag"] = "changed"
    elif change == "delayed":
        client.secret["versionDestroyTtl"] = "86400s"
    with pytest.raises(ValueError):
        retire(client, plan, lambda *_: None)
    assert client.destroyed == []


def test_recovery_failure_prevents_destruction():
    client = FakeClient()

    def unavailable(*_):
        raise ValueError("archive verification failed")

    with pytest.raises(ValueError, match="archive verification failed"):
        retire(client, candidate(client), unavailable)
    assert client.destroyed == []
