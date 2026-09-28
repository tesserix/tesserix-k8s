#!/usr/bin/env python3
"""Create Langfuse's confidential Zitadel OIDC app and store its credentials.

The restricted Langfuse project must already exist. Supply ZITADEL_PAT and a
short-lived BAO_TOKEN with exact-path create/read/update access to the two
Langfuse OIDC destinations. Credentials are never printed.
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from migrate_fe3dr_secret import MigrationError, OpenBao, destination_value
import urllib.error
import urllib.request

API = "https://auth.tesserix.app"
ORGANIZATION = "TESSERIX"
PROJECT_NAME = "Langfuse"
APP_NAME = "langfuse-web"
REDIRECT_URI = "https://langfuse.tesserix.app/api/auth/callback/custom"
POST_LOGOUT_URI = "https://langfuse.tesserix.app"
SECRETS = {
    "clientId": "langfuse/app/langfuse-zitadel-client-id",
    "clientSecret": "langfuse/app/langfuse-zitadel-client-secret",
}


class Client:
    def __init__(self, token: str, org: str | None = None):
        self.token, self.org = token, org

    def __call__(self, method: str, path: str, body: dict | None = None):
        request = urllib.request.Request(
            f"{API}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
        )
        request.add_header("Authorization", f"Bearer {self.token}")
        request.add_header("Content-Type", "application/json")
        request.add_header("User-Agent", "tesserix-langfuse-oidc/1.0")
        if self.org:
            request.add_header("x-zitadel-orgid", self.org)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            try:
                return error.code, json.loads(error.read() or b"{}")
            except json.JSONDecodeError:
                return error.code, {}

    def expect(self, method: str, path: str, body: dict | None = None) -> dict:
        status, payload = self(method, path, body)
        if status != 200:
            raise SystemExit(
                f"Identity request failed: HTTP {status}; payload withheld"
            )
        return payload


def store(name: str, value: str, bao: OpenBao) -> None:
    if name not in SECRETS.values() or not value:
        raise ValueError(
            "Require an exact Langfuse OIDC destination and nonempty value"
        )
    path = "kv/data/" + name
    existing = bao.request("GET", path)
    version = 0
    if existing is not None:
        previous, version = destination_value(existing)
        if previous == value.encode():
            return
    written = bao.request(
        "POST",
        path,
        {
            "options": {"cas": version},
            "data": {"value": value},
        },
    )
    actual, stored_version = destination_value(bao.request("GET", path))
    if actual != value.encode() or stored_version != written["data"]["version"]:
        raise MigrationError("OpenBao readback differs; payload withheld")


def writer_client() -> OpenBao:
    token = os.environ.pop("BAO_TOKEN", "")
    if not token:
        raise ValueError("A short-lived scoped BAO_TOKEN is required")
    bao = OpenBao(os.environ.get("BAO_ADDR", "http://127.0.0.1:18200"), token)
    identity = bao.request("GET", "auth/token/lookup-self")["data"]
    if not 0 < identity.get("ttl", 0) <= 900 or "root" in identity.get("policies", []):
        raise ValueError("Require a short-lived non-root writer")
    paths = ["kv/data/" + path for path in SECRETS.values()]
    caps = bao.request("POST", "sys/capabilities-self", {"paths": paths})
    for path in paths:
        if set(caps.get(path, [])) != {"create", "read", "update"}:
            raise ValueError("Require exact create/read/update access")
    return bao


def main() -> None:
    token = os.environ.get("ZITADEL_PAT") or sys.exit(
        "export ZITADEL_PAT first (see docstring)"
    )
    bao = writer_client()
    try:
        regenerate = "--regenerate" in sys.argv
        client = Client(token)
        organizations = client.expect(
            "POST", "/admin/v1/orgs/_search", {"query": {"limit": 100}}
        ).get("result", [])
        organization = next(
            (item for item in organizations if item["name"] == ORGANIZATION), None
        )
        if organization is None:
            raise SystemExit(f"organization {ORGANIZATION!r} does not exist")
        client.org = organization["id"]

        projects = client.expect(
            "POST", "/management/v1/projects/_search", {"query": {"limit": 100}}
        ).get("result", [])
        project = next(
            (item for item in projects if item["name"] == PROJECT_NAME), None
        )
        if project is None:
            raise SystemExit(
                f"project {PROJECT_NAME!r} does not exist; reconcile its ZitadelProject claim first"
            )
        project_id = project["id"]

        apps = client.expect(
            "POST",
            f"/management/v1/projects/{project_id}/apps/_search",
            {"query": {"limit": 100}},
        ).get("result", [])
        app = next((item for item in apps if item["name"] == APP_NAME), None)
        if app and not regenerate:
            raise SystemExit(
                f"app {APP_NAME!r} already exists; its secret cannot be re-read — "
                "rerun with --regenerate to mint a new one"
            )

        if app:
            created = client.expect(
                "POST",
                f"/management/v1/projects/{project_id}/apps/{app['id']}/oidc_config/_generate_client_secret",
            )
            client_id = app["oidcConfig"]["clientId"]
        else:
            created = client.expect(
                "POST",
                f"/management/v1/projects/{project_id}/apps/oidc",
                {
                    "name": APP_NAME,
                    "redirectUris": [REDIRECT_URI],
                    "postLogoutRedirectUris": [POST_LOGOUT_URI],
                    "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
                    "grantTypes": [
                        "OIDC_GRANT_TYPE_AUTHORIZATION_CODE",
                        "OIDC_GRANT_TYPE_REFRESH_TOKEN",
                    ],
                    "appType": "OIDC_APP_TYPE_WEB",
                    "authMethodType": "OIDC_AUTH_METHOD_TYPE_BASIC",
                    "accessTokenType": "OIDC_TOKEN_TYPE_BEARER",
                    "devMode": False,
                },
            )
            client_id = created["clientId"]

        store(SECRETS["clientId"], client_id, bao)
        store(SECRETS["clientSecret"], created["clientSecret"], bao)
        print("OpenBao credentials verified; External Secrets will refresh")
    finally:
        bao.request("POST", "auth/token/revoke-self", {})


if __name__ == "__main__":
    try:
        main()
    except (MigrationError, ValueError, KeyError, TypeError, OSError):
        sys.exit("Credential operation failed; details withheld. Check scoped access.")
