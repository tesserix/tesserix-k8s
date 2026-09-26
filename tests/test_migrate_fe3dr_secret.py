import importlib.util
import pathlib

import pytest

ROOT = pathlib.Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location(
    "migration", ROOT / "scripts/migrate_fe3dr_secret.py"
)
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


def test_copy_preserves_unicode_and_newline_and_uses_create_only_cas():
    calls = []
    value = "credential-λ\n"

    def request(method, path, body=None):
        calls.append((method, path, body))
        if method == "POST":
            return {"data": {"version": 1}}
        if len(calls) == 1:
            return None
        return {"data": {"data": {"value": value}, "metadata": {"version": 1}}}

    assert migration.copy_secret(request, value.encode()) == ("created", 1)
    assert calls[1][2] == {"options": {"cas": 0}, "data": {"value": value}}


def test_existing_equal_value_is_noop():
    calls = []

    def request(method, path, body=None):
        calls.append(method)
        return {"data": {"data": {"value": "same"}, "metadata": {"version": 2}}}

    assert migration.copy_secret(request, b"same") == ("unchanged", 2)
    assert calls == ["GET"]


def test_existing_different_value_is_never_overwritten():
    def request(method, path, body=None):
        assert method == "GET"
        return {"data": {"data": {"value": "different"}, "metadata": {"version": 1}}}

    with pytest.raises(migration.MigrationError, match="differs"):
        migration.copy_secret(request, b"source")


def test_copy_mismatch_fails_without_leaking_payload():
    responses = iter(
        [
            None,
            {"data": {"version": 1}},
            {"data": {"data": {"value": "wrong"}, "metadata": {"version": 1}}},
        ]
    )
    with pytest.raises(migration.MigrationError, match="verification failed") as error:
        migration.copy_secret(lambda *args: next(responses), b"private-credential")
    assert "private-credential" not in str(error.value)


@pytest.mark.parametrize(
    "data",
    [
        {"ttl": 901, "policies": ["fe3dr-migrate-openexchangerates"]},
        {"ttl": 0, "policies": ["fe3dr-migrate-openexchangerates"]},
        {"ttl": 600, "policies": ["root"]},
        {
            "ttl": 600,
            "policies": ["fe3dr-migrate-openexchangerates"],
            "identity_policies": ["admin"],
        },
    ],
)
def test_rejects_long_lived_or_broad_token(data):
    with pytest.raises(migration.MigrationError):
        migration.validate_token(data)


def test_accepts_short_lived_scoped_token():
    migration.validate_token(
        {"ttl": 600, "policies": ["default", "fe3dr-migrate-openexchangerates"]}
    )


def test_prepare_app_preserves_file_and_is_idempotent(tmp_path):
    target = tmp_path / "values-prod.yaml"
    target.write_text("# existing settings\ngcp:\n  projectId: example\n")
    migration.prepare_app(target)
    first = target.read_text()
    migration.prepare_app(target)
    assert target.read_text() == first
    assert first.startswith("# existing settings\ngcp:\n  projectId: example\n")
    assert "exchangeRatePilot:\n    enabled: true" in first


def test_prepare_app_refuses_conflicting_existing_config(tmp_path):
    target = tmp_path / "values-prod.yaml"
    target.write_text("openbao:\n  custom: true\n")
    with pytest.raises(migration.MigrationError):
        migration.prepare_app(target)
    assert target.read_text() == "openbao:\n  custom: true\n"


@pytest.mark.parametrize(
    "address",
    [
        "http://openbao.example.com",
        "https://user:password@example.com",
        "https://example.com/?token=secret",
        "file:///tmp/bao",
    ],
)
def test_rejects_unsafe_token_transport(address):
    with pytest.raises(migration.MigrationError):
        migration.OpenBao(address, "test-token")


def test_redirect_does_not_forward_token():
    with pytest.raises(migration.MigrationError, match="redirect refused"):
        migration.NoRedirect().redirect_request(
            None, None, 307, "", {}, "https://other.example"
        )


@pytest.mark.parametrize("failure", [None, "source", "revoke"])
def test_cli_copies_verifies_revokes_then_prepares_app(tmp_path, failure):
    import http.server
    import json
    import os
    import shutil
    import subprocess
    import sys
    import threading

    secret = "test-only-λ\n"
    state = {"value": None, "revoked": False}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body):
            self.send_response(status)
            self.end_headers()
            self.wfile.write(json.dumps(body).encode())

        def do_GET(self):
            assert self.headers["X-Vault-Token"] == "test-only-token"
            if self.path == "/v1/auth/token/lookup-self":
                self.reply(200, {"data": {"ttl": 600, "policies": [migration.POLICY]}})
            elif state["value"] is None:
                self.reply(404, {})
            else:
                self.reply(
                    200,
                    {
                        "data": {
                            "data": {"value": state["value"]},
                            "metadata": {"version": 1},
                        }
                    },
                )

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path == "/v1/auth/token/revoke-self":
                state["revoked"] = failure != "revoke"
                self.reply(403 if failure == "revoke" else 200, {})
            else:
                assert self.path == "/v1/" + migration.DESTINATION
                assert body["options"] == {"cas": 0}
                state["value"] = body["data"]["value"]
                self.reply(200, {"data": {"version": 1}})

    script = tmp_path / "scripts/migrate_fe3dr_secret.py"
    script.parent.mkdir()
    shutil.copyfile(ROOT / "scripts/migrate_fe3dr_secret.py", script)
    target = tmp_path / "charts/apps/homechef-api/values-prod.yaml"
    target.parent.mkdir(parents=True)
    target.write_text("# original\ngcp: {}\n")
    executable = tmp_path / "gcloud"
    executable.write_text(
        f"#!{sys.executable}\nimport sys, json, os, base64\n"
        "assert 'BAO_TOKEN' not in os.environ\n"
        "args=sys.argv[1:]\n"
        "assert not any(arg.startswith('--out-file') for arg in args)\n"
        "if args[0]=='auth': print('operator@example.com')\n"
        f"elif 'describe' in args: print(json.dumps({{'state':'ENABLED','name':'projects/123/secrets/{migration.SOURCE}/versions/1'}}))\n"
        f"elif {failure == 'source'!r}: print('sensitive-error-payload', file=sys.stderr); sys.exit(1)\n"
        f"else: assert '--format=get(payload.data)' in args; sys.stdout.buffer.write(base64.urlsafe_b64encode({secret.encode()!r}) + b'\\n')\n"
    )
    executable.chmod(0o700)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(script),
                "--execute",
                "--version",
                "1",
                "--account",
                "operator@example.com",
                "--prepare-app",
                "--bao-addr",
                f"http://127.0.0.1:{server.server_port}",
            ],
            env={
                **os.environ,
                "PATH": str(tmp_path) + os.pathsep + os.environ["PATH"],
                "BAO_TOKEN": "test-only-token",
            },
            capture_output=True,
            text=True,
            timeout=20,
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    assert (result.returncode == 0) == (failure is None)
    assert state["revoked"] == (failure != "revoke")
    assert state["value"] == (None if failure == "source" else secret)
    assert ("enabled: true" in target.read_text()) == (failure is None)
    for sensitive in (secret.strip(), "test-only-token", "sensitive-error-payload"):
        assert sensitive not in result.stdout + result.stderr
