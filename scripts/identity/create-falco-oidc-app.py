#!/usr/bin/env python3
"""Creates the Falco UI OIDC app in Zitadel and stores its credentials in GCP SM.

The falco-ui-gateway oauth2-proxy reads prod-falco-oidc-client-id and
prod-falco-oidc-client-secret through ESO; until both exist the deployment sits
in CreateContainerConfigError. The client secret is shown once at create time,
so this writes it straight to Secret Manager and never prints it.

Idempotent: an existing project or app is reused, but an existing app's secret
cannot be re-read — rerun with --regenerate to mint a new one.

  export ZITADEL_PAT=$(kubectl get secret iam-admin-pat -n zitadel \
      -o jsonpath='{.data.pat}' | base64 -d)
  ./create-falco-oidc-app.py
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://auth.tesserix.app"
GCP_PROJECT = "tesseracthub-480811"
PROJECT_NAME = "falco"
APP_NAME = "falco-ui"
REDIRECT_URI = "https://falco.tesserix.app/oauth2/callback"
POST_LOGOUT_URI = "https://falco.tesserix.app"
SECRETS = {"clientId": "prod-falco-oidc-client-id",
           "clientSecret": "prod-falco-oidc-client-secret"}


class Client:
    def __init__(self, token, org=None):
        self.token, self.org = token, org

    def __call__(self, method, path, body=None):
        req = urllib.request.Request(f"{API}{path}",
                                     data=json.dumps(body).encode() if body is not None else None,
                                     method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json")
        # Cloudflare fronts auth.tesserix.app and 1010s the default urllib UA.
        req.add_header("User-Agent", "tesserix-falco-oidc/1.0")
        if self.org:
            req.add_header("x-zitadel-orgid", self.org)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as err:
            try:
                return err.code, json.loads(err.read() or b"{}")
            except json.JSONDecodeError:
                return err.code, {}

    def expect(self, method, path, body=None):
        status, payload = self(method, path, body)
        if status != 200:
            raise SystemExit(f"{method} {path} failed: {status} {payload}")
        return payload


def store(name, value):
    """Create-or-add a Secret Manager version without the value touching argv."""
    exists = subprocess.run(
        ["gcloud", "secrets", "describe", name, f"--project={GCP_PROJECT}"],
        capture_output=True).returncode == 0
    if not exists:
        subprocess.run(["gcloud", "secrets", "create", name,
                        f"--project={GCP_PROJECT}", "--replication-policy=automatic"],
                       check=True, capture_output=True)
    subprocess.run(["gcloud", "secrets", "versions", "add", name,
                    f"--project={GCP_PROJECT}", "--data-file=-"],
                   input=value.encode(), check=True, capture_output=True)
    print(f"stored {name}")


def main():
    token = os.environ.get("ZITADEL_PAT") or sys.exit("export ZITADEL_PAT first (see docstring)")
    regenerate = "--regenerate" in sys.argv

    client = Client(token)
    orgs = client.expect("POST", "/admin/v1/orgs/_search", {"query": {"limit": 100}})["result"]
    client.org = next(o["id"] for o in orgs if o["name"] == "TESSERIX")

    projects = client.expect("POST", "/management/v1/projects/_search",
                             {"query": {"limit": 100}}).get("result", [])
    project = next((p for p in projects if p["name"] == PROJECT_NAME), None)
    project_id = project["id"] if project else \
        client.expect("POST", "/management/v1/projects", {"name": PROJECT_NAME})["id"]

    apps = client.expect("POST", f"/management/v1/projects/{project_id}/apps/_search",
                         {"query": {"limit": 100}}).get("result", [])
    app = next((a for a in apps if a["name"] == APP_NAME), None)

    if app and not regenerate:
        raise SystemExit(f"app {APP_NAME!r} already exists (clientId "
                         f"{app['oidcConfig']['clientId']}); its secret cannot be "
                         "re-read — rerun with --regenerate to mint a new one")

    if app and regenerate:
        created = client.expect("POST",
                                f"/management/v1/projects/{project_id}/apps/{app['id']}/oidc_config/_generate_client_secret")
        client_id = app["oidcConfig"]["clientId"]
    else:
        created = client.expect("POST", f"/management/v1/projects/{project_id}/apps/oidc", {
            "name": APP_NAME,
            "redirectUris": [REDIRECT_URI],
            "postLogoutRedirectUris": [POST_LOGOUT_URI],
            "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
            "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
            "appType": "OIDC_APP_TYPE_WEB",
            "authMethodType": "OIDC_AUTH_METHOD_TYPE_BASIC",
            "accessTokenType": "OIDC_TOKEN_TYPE_BEARER",
            "devMode": False,
        })
        client_id = created["clientId"]

    store(SECRETS["clientId"], client_id)
    store(SECRETS["clientSecret"], created["clientSecret"])
    print(f"done — clientId {client_id}; ESO refreshes falco-ui-oauth2-secrets within 1h,"
          "\nor force it: kubectl annotate externalsecret falco-ui-oauth2-secrets -n falco"
          " force-sync=$(date +%s) --overwrite")


if __name__ == "__main__":
    main()
