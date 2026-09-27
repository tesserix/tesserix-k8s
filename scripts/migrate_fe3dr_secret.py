#!/usr/bin/env python3
"""Copy the fe3dr exchange-rate pilot using an operator-issued temporary token."""

import argparse
import base64
import getpass
import hmac
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PROJECT = "tesseracthub-480811"
SOURCE = "prod-homechef-openexchangerates-app-id"
DESTINATION = "kv/data/homechef/homechef-api/fe3dr-openexchangerates-app-id"
POLICY = "fe3dr-migrate-openexchangerates"
APP_VALUES = (
    Path(__file__).resolve().parents[1] / "charts/apps/homechef-api/values-prod.yaml"
)
APP_BLOCK = "\n# fe3dr OpenBao pilot (#1159)\nopenbao:\n  exchangeRatePilot:\n    enabled: true\n"


class MigrationError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise MigrationError(
            "OpenBao redirect refused; use the active service endpoint"
        )


class OpenBao:
    def __init__(self, address, token):
        parsed = urllib.parse.urlsplit(address)
        if (
            parsed.scheme not in ("http", "https")
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
            or parsed.path not in ("", "/")
            or (
                parsed.scheme == "http"
                and parsed.hostname not in ("127.0.0.1", "::1", "localhost")
            )
        ):
            raise MigrationError(
                "Use HTTPS or a loopback kubectl port-forward for BAO_ADDR"
            )
        self.address = address.rstrip("/")
        self.token = token
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect()
        )

    def request(self, method, path, body=None):
        request = urllib.request.Request(
            f"{self.address}/v1/{path}",
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Content-Type": "application/json", "X-Vault-Token": self.token},
        )
        try:
            with self.opener.open(request, timeout=20) as response:
                return json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            if (
                error.code == 404
                and method == "GET"
                and path.startswith(
                    (
                        "kv/data/homechef/",
                        "kv/data/homechef-development/",
                        "kv/data/blog/app/",
                        "kv/data/roamie/app/",
                        "kv/data/roamie-development/app/",
                    )
                )
            ):
                return None
            raise MigrationError(
                f"OpenBao {method} failed (HTTP {error.code}); response withheld"
            ) from None
        except (OSError, ValueError):
            raise MigrationError(
                "OpenBao transport/response failed; details withheld"
            ) from None


def validate_token(data, policy=POLICY):
    policies = set(data.get("policies", [])) | set(data.get("identity_policies", []))
    if (
        not 0 < data.get("ttl", 0) <= 900
        or policy not in policies
        or policies - {policy, "default"}
    ):
        raise MigrationError(
            "Require a <=15-minute token with only the pilot policy and optional default policy"
        )


def destination_value(response):
    try:
        data = response["data"]
        value = data["data"]["value"]
        if not isinstance(value, str) or set(data["data"]) != {"value"}:
            raise ValueError
        return value.encode("utf-8"), data["metadata"]["version"]
    except (KeyError, TypeError, ValueError):
        raise MigrationError(
            "Destination shape differs from the one-field pilot contract"
        ) from None


def copy_secret(request, source, destination=DESTINATION):
    try:
        value = source.decode("utf-8")
    except UnicodeDecodeError:
        raise MigrationError(
            "Pilot source must be UTF-8; no implicit encoding conversion"
        ) from None
    if not source:
        raise MigrationError("Refusing an empty source credential")
    existing = request("GET", destination)
    if existing is not None:
        current, version = destination_value(existing)
        if not hmac.compare_digest(source, current):
            raise MigrationError("Destination differs; refusing overwrite")
        return "unchanged", version
    # CAS=0 prevents replacing an existing, concurrently created or soft-deleted key.
    written = request(
        "POST", destination, {"options": {"cas": 0}, "data": {"value": value}}
    )
    verified = request("GET", destination)
    if verified is None:
        raise MigrationError("Copy verification failed; destination unavailable")
    current, version = destination_value(verified)
    if (
        not hmac.compare_digest(source, current)
        or version != written["data"]["version"]
    ):
        raise MigrationError("Copy verification failed; app connection not prepared")
    return "created", version


def app_content(target):
    content = target.read_text()
    if content.endswith(APP_BLOCK):
        return content
    if re.search(r"^openbao\s*:", content, re.MULTILINE):
        raise MigrationError(
            "Existing OpenBao production config requires manual review"
        )
    return content + APP_BLOCK


def prepare_app(target):
    content = app_content(target)
    target.write_text(content)


def gcloud(*args):
    # Never forward the temporary OpenBao token to child processes.
    env = {key: value for key, value in os.environ.items() if key != "BAO_TOKEN"}
    try:
        return subprocess.run(
            ["gcloud", *args],
            check=True,
            capture_output=True,
            timeout=60,
            env=env,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        raise MigrationError("gcloud command failed; stdout/stderr withheld") from None


def execute(args, token):
    bao = OpenBao(args.bao_addr, token)
    try:
        validate_token(bao.request("GET", "auth/token/lookup-self")["data"])
        if args.prepare_app:
            app_content(APP_VALUES)
        account = (
            gcloud("auth", "list", "--filter=status:ACTIVE", "--format=value(account)")
            .decode()
            .strip()
        )
        if account != args.account:
            raise MigrationError("Active GCP account does not match --account")
        description = json.loads(
            gcloud(
                "secrets",
                "versions",
                "describe",
                args.version,
                f"--secret={SOURCE}",
                f"--project={PROJECT}",
                "--format=json",
            )
        )
        expected = f"/secrets/{SOURCE}/versions/{args.version}"
        if description.get("state") != "ENABLED" or not description.get(
            "name", ""
        ).endswith(expected):
            raise MigrationError("Pinned GCP version is not enabled or does not match")
        print(
            f"Account: {account}; project: {PROJECT}; source: {SOURCE}@{args.version}"
        )
        print(
            f"Target: {DESTINATION}; app namespace: homechef (local GitOps preparation only)"
        )
        encoded = gcloud(
            "secrets",
            "versions",
            "access",
            args.version,
            f"--secret={SOURCE}",
            f"--project={PROJECT}",
            "--format=get(payload.data)",
        ).strip()
        source = base64.b64decode(encoded, altchars=b"-_", validate=True)
        status, version = copy_secret(bao.request, source)
        print(f"Copy {status}; equality PASS; OpenBao version {version}")
    finally:
        try:
            bao.request("POST", "auth/token/revoke-self", {})
            print("Temporary OpenBao token revoked")
        except MigrationError:
            raise MigrationError(
                "Token revocation failed; revoke it through the issuer. App connection not prepared"
            ) from None
    if args.prepare_app:
        prepare_app(APP_VALUES)
        print(
            "Local production values prepared. Review and deploy through GitOps; no cluster changes made."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Copy using a dedicated temporary token; default is plan only",
    )
    parser.add_argument(
        "--version", help="Pinned numeric GCP secret version (never latest)"
    )
    parser.add_argument("--account", help="Expected active GCP account")
    parser.add_argument(
        "--bao-addr", default=os.environ.get("BAO_ADDR", "http://127.0.0.1:18200")
    )
    parser.add_argument(
        "--prepare-app",
        action="store_true",
        help="After successful copy/revocation, enable the pilot in local production values",
    )
    args = parser.parse_args()
    if not args.execute:
        print(
            f"PLAN: {PROJECT}/{SOURCE}@<pinned-version> -> {DESTINATION}, field=value"
        )
        print(
            "No reads/writes. Execute needs --version, --account and BAO_TOKEN (or hidden prompt)."
        )
        print(
            "Temporary token policy: fe3dr-migrate-openexchangerates; remaining TTL <=900s."
        )
        return 0
    if (
        not args.account
        or not args.version
        or not re.fullmatch(r"[1-9][0-9]*", args.version)
    ):
        parser.error("--execute requires --account and a numeric --version")
    token = os.environ.pop("BAO_TOKEN", "") or getpass.getpass(
        "Temporary OpenBao token (hidden): "
    )
    if not token.strip():
        parser.error("A temporary token is required")
    try:
        execute(args, token.strip())
    except (MigrationError, KeyError, TypeError, ValueError, OSError):
        # Only deliberately sanitized operational messages are safe to display.
        error = sys.exc_info()[1]
        print(
            str(error)
            if isinstance(error, MigrationError)
            else "Migration failed; details withheld",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
