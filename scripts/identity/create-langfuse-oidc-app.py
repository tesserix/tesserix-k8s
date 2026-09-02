#!/usr/bin/env python3
"""Create Langfuse's confidential Zitadel OIDC app and store its credentials.

The restricted ``Langfuse`` project must already be reconciled by the identity
operator. Credentials are written directly to GCP Secret Manager and are never
printed or passed in process arguments.

  export ZITADEL_PAT=$(kubectl get secret iam-admin-pat -n zitadel \
      -o jsonpath='{.data.pat}' | base64 -d)
  ./scripts/identity/create-langfuse-oidc-app.py
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://auth.tesserix.app"
GCP_PROJECT = "tesseracthub-480811"
ORGANIZATION = "TESSERIX"
PROJECT_NAME = "Langfuse"
APP_NAME = "langfuse-web"
REDIRECT_URI = "https://langfuse.tesserix.app/api/auth/callback/custom"
POST_LOGOUT_URI = "https://langfuse.tesserix.app"
SECRETS = {
    "clientId": "prod-langfuse-zitadel-client-id",
    "clientSecret": "prod-langfuse-zitadel-client-secret",
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
            raise SystemExit(f"{method} {path} failed: {status} {payload}")
        return payload


def store(name: str, value: str) -> None:
    """Create or version a secret without placing its value in argv."""
    exists = (
        subprocess.run(
            ["gcloud", "secrets", "describe", name, f"--project={GCP_PROJECT}"],
            capture_output=True,
        ).returncode
        == 0
    )
    if not exists:
        subprocess.run(
            [
                "gcloud",
                "secrets",
                "create",
                name,
                f"--project={GCP_PROJECT}",
                "--replication-policy=automatic",
            ],
            check=True,
            capture_output=True,
        )
    subprocess.run(
        [
            "gcloud",
            "secrets",
            "versions",
            "add",
            name,
            f"--project={GCP_PROJECT}",
            "--data-file=-",
        ],
        input=value.encode(),
        check=True,
        capture_output=True,
    )
    print(f"stored {name}")


def main() -> None:
    token = os.environ.get("ZITADEL_PAT") or sys.exit(
        "export ZITADEL_PAT first (see docstring)"
    )
    regenerate = "--regenerate" in sys.argv
    client = Client(token)
    organizations = client.expect(
        "POST", "/admin/v1/orgs/_search", {"query": {"limit": 100}}
    ).get("result", [])
    organization = next((item for item in organizations if item["name"] == ORGANIZATION), None)
    if organization is None:
        raise SystemExit(f"organization {ORGANIZATION!r} does not exist")
    client.org = organization["id"]

    projects = client.expect(
        "POST", "/management/v1/projects/_search", {"query": {"limit": 100}}
    ).get("result", [])
    project = next((item for item in projects if item["name"] == PROJECT_NAME), None)
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

    store(SECRETS["clientId"], client_id)
    store(SECRETS["clientSecret"], created["clientSecret"])
    print("done — credentials stored; External Secrets will refresh within 1h")


if __name__ == "__main__":
    main()
