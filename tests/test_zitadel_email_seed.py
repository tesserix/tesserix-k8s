import importlib.util
import io
import json
from pathlib import Path
from urllib.error import HTTPError

import pytest

ROOT = Path(__file__).resolve().parents[1]


def load_seed():
    spec = importlib.util.spec_from_file_location(
        "email_seed", ROOT / "external-secrets/prod/zitadel/email-secret-seed.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_seed_creates_absent_password_using_create_only_cas(monkeypatch):
    seed = load_seed()
    requests = []

    def respond(request, timeout):
        assert timeout == 15
        requests.append(request)
        if request.method == "GET":
            raise HTTPError(request.full_url, 404, "absent", {}, None)
        return io.BytesIO(b"{}")

    monkeypatch.setattr(seed.urllib.request, "urlopen", respond)
    seed.seed("test-token")
    assert len(requests) == 2
    assert all(r.full_url == seed.BASE + seed.KEY for r in requests)
    payload = json.loads(requests[1].data)
    assert payload["options"] == {"cas": 0}
    assert len(payload["data"]["value"]) == 64
    assert bytes.fromhex(payload["data"]["value"])


def test_seed_preserves_existing_password(monkeypatch):
    seed = load_seed()
    requests = []

    def respond(request, timeout):
        requests.append(request)
        return io.BytesIO(json.dumps({"data": {"data": {"value": "a" * 64}}}).encode())

    monkeypatch.setattr(seed.urllib.request, "urlopen", respond)
    seed.seed("test-token")
    assert [r.method for r in requests] == ["GET"]


@pytest.mark.parametrize("result", [403, {"data": {"data": {"value": "invalid"}}}])
def test_seed_fails_closed_on_denied_read_and_invalid_existing_value(
    monkeypatch, result
):
    seed = load_seed()
    methods = []

    def respond(request, timeout):
        methods.append(request.method)
        if isinstance(result, int):
            raise HTTPError(request.full_url, result, "denied", {}, None)
        return io.BytesIO(json.dumps(result).encode())

    monkeypatch.setattr(seed.urllib.request, "urlopen", respond)
    with pytest.raises((HTTPError, ValueError)):
        seed.seed("test-token")
    assert methods == ["GET"]


@pytest.mark.parametrize("exists", [False, True])
def test_seed_never_overwrites_deleted_secret_and_accepts_concurrent_creation(
    monkeypatch, exists
):
    seed = load_seed()
    methods = []

    def respond(request, timeout):
        methods.append(request.method)
        if request.method == "POST":
            assert json.loads(request.data)["options"] == {"cas": 0}
            raise HTTPError(request.full_url, 400, "CAS mismatch", {}, None)
        if len(methods) == 1 or not exists:
            raise HTTPError(request.full_url, 404, "absent", {}, None)
        return io.BytesIO(json.dumps({"data": {"data": {"value": "b" * 64}}}).encode())

    monkeypatch.setattr(seed.urllib.request, "urlopen", respond)
    if exists:
        seed.seed("test-token")
    else:
        with pytest.raises(HTTPError):
            seed.seed("test-token")
    assert methods == ["GET", "POST", "GET"]


def test_seed_revokes_its_token_when_secret_access_fails(monkeypatch, capsys):
    seed = load_seed()
    requests = []
    monkeypatch.setattr(seed.Path, "read_text", lambda self: "test-workload-jwt")

    def respond(request, timeout):
        requests.append(request)
        if request.full_url.endswith("auth/kubernetes/login"):
            return io.BytesIO(b'{"auth":{"client_token":"test-bao-token"}}')
        if request.full_url.endswith("auth/token/revoke-self"):
            return io.BytesIO(b"{}")
        raise HTTPError(request.full_url, 403, "denied", {}, None)

    monkeypatch.setattr(seed.urllib.request, "urlopen", respond)
    with pytest.raises(HTTPError):
        seed.main()
    assert requests[-1].full_url.endswith("auth/token/revoke-self")
    assert capsys.readouterr().out == ""
