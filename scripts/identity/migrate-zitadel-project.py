#!/usr/bin/env python3
"""Recreates a Zitadel project and its OIDC apps in another organisation.

Zitadel has no API to move a project between orgs, so a "move" is a recreate
plus a manual cutover: the new app gets a new clientId and a new client secret,
which have to reach Secret Manager before anything is pointed at them.

Dry run by default. Nothing is ever deleted — the source project stays live so
the cutover can be rolled back by pointing the app back at the old clientId.

  export ZITADEL_PAT=$(kubectl get secret iam-admin-pat -n zitadel \
      -o jsonpath='{.data.pat}' | base64 -d)
  ./migrate-zitadel-project.py --project tesserix-blog --to-org TESSERIX
  ./migrate-zitadel-project.py --project tesserix-blog --to-org TESSERIX --apply
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

# Server-owned or identity fields: a create call must mint its own.
_APP_READONLY = frozenset({"clientId", "clientSecret", "details", "state", "id",
                           "complianceProblems", "noneCompliant"})


def create_payload(app):
    """Turn an app read from the API into the body that recreates it elsewhere.

    Protobuf defaults come back omitted, so appType and authMethodType are absent
    on a basic-auth web app and have to be restated — left out, the new app is
    created as the wrong type and its secret never validates.
    """
    oidc = {key: value for key, value in app["oidcConfig"].items() if key not in _APP_READONLY}
    oidc.setdefault("appType", "OIDC_APP_TYPE_WEB")
    oidc.setdefault("authMethodType", "OIDC_AUTH_METHOD_TYPE_BASIC")
    oidc.setdefault("devMode", False)
    return dict(oidc, name=app["name"])


def _decode(payload):
    """Gateway errors come back as HTML, so a failed call must not die in the parser."""
    try:
        return json.loads(payload or b"{}")
    except json.JSONDecodeError:
        return {"raw": payload[:400].decode("utf-8", "replace")}


class Client:
    def __init__(self, api, token, org=None):
        self.api, self.token, self.org = api, token, org

    def __call__(self, method, path, body=None, org=None):
        url = f"{self.api}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json")
        # Cloudflare fronts auth.tesserix.app and 1010s the default Python-urllib UA.
        req.add_header("User-Agent", "tesserix-project-migration/1.0")
        scope = org or self.org
        if scope:
            req.add_header("x-zitadel-orgid", scope)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, _decode(resp.read())
        except urllib.error.HTTPError as err:
            return err.code, _decode(err.read())

    def expect(self, method, path, body=None, org=None):
        status, payload = self(method, path, body, org)
        if status != 200:
            raise SystemExit(f"{method} {path} failed: {status} {payload}")
        return payload


def find_org(client, name):
    orgs = client.expect("POST", "/admin/v1/orgs/_search", {"query": {"limit": 100}}).get("result", [])
    org = next((o for o in orgs if o["name"] == name), None)
    if not org:
        raise SystemExit(f"org {name!r} not found")
    return org["id"]


def find_project(client, org_id, name):
    projects = client.expect("POST", "/management/v1/projects/_search",
                             {"query": {"limit": 100}}, org=org_id).get("result", [])
    return next((p for p in projects if p["name"] == name), None)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", required=True)
    parser.add_argument("--from-org", default="ZITADEL")
    parser.add_argument("--to-org", required=True)
    parser.add_argument("--api", default="https://auth.tesserix.app")
    parser.add_argument("--apply", action="store_true", help="without this, only report the plan")
    args = parser.parse_args()

    token = os.environ.get("ZITADEL_PAT")
    if not token:
        raise SystemExit("ZITADEL_PAT is not set")
    client = Client(args.api, token)

    source_org, target_org = find_org(client, args.from_org), find_org(client, args.to_org)
    source = find_project(client, source_org, args.project)
    if not source:
        raise SystemExit(f"project {args.project!r} not found in {args.from_org}")
    if find_project(client, target_org, args.project):
        raise SystemExit(f"project {args.project!r} already exists in {args.to_org}; nothing to do")

    apps = client.expect("POST", f"/management/v1/projects/{source['id']}/apps/_search",
                         {"query": {"limit": 100}}, org=source_org).get("result", [])
    oidc_apps = [client.expect("GET", f"/management/v1/projects/{source['id']}/apps/{a['id']}",
                               org=source_org)["app"]
                 for a in apps if "oidcConfig" in a]

    print(f"{args.project}: {args.from_org} -> {args.to_org}")
    for app in oidc_apps:
        print(f"  app {app['name']}  clientId {app['oidcConfig']['clientId']} -> (new)")
        for uri in app["oidcConfig"].get("redirectUris", []):
            print(f"    redirect {uri}")
    if not args.apply:
        print("\ndry run; re-run with --apply to create these in the target org")
        return 0

    project_id = client.expect("POST", "/management/v1/projects",
                               {"name": args.project}, org=target_org)["id"]
    print(f"\ncreated project {project_id} in {args.to_org}")

    for app in oidc_apps:
        created = client.expect("POST", f"/management/v1/projects/{project_id}/apps/oidc",
                                create_payload(app), org=target_org)
        print(f"\napp {app['name']}")
        print(f"  clientId     {created['clientId']}")
        print(f"  clientSecret {created.get('clientSecret', '(none - public client)')}")

    print("\nNext, in order:")
    print("  1. store the new secret:  gcloud secrets versions add <secret> --project=tesseracthub-480811 --data-file=-")
    print("  2. update the clientId in the app's Helm values, commit, let ArgoCD sync")
    print("  3. verify a real login, then delete the old project from", args.from_org)
    return 0


if __name__ == "__main__":
    sys.exit(main())
