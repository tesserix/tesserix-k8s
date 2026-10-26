#!/usr/bin/env python3
"""Provision Rocket.Chat credentials after its restricted project is reconciled.

Requires ZITADEL_PAT and a <=15 minute non-root BAO_TOKEN scoped to the six
exact production paths below. Existing credentials are never rotated.
"""

import base64
import importlib.util
import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from migrate_fe3dr_secret import MigrationError, OpenBao, destination_value

spec = importlib.util.spec_from_file_location(
    "langfuse_identity", Path(__file__).with_name("create-langfuse-oidc-app.py")
)
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)

PREFIX = "kv/data/rocketchat/prod/app/rocketchat-"
NAMES = (
    "mongodb-root-password",
    "mongodb-password",
    "mongodb-keyfile",
    "mongodb-uri",
    "zitadel-client-id",
    "zitadel-client-secret",
)
MEMBERS = {"samyak.rout@gmail.com", "mahesh.sangawar@gmail.com"}


def read(bao, name):
    if name not in NAMES:
        raise ValueError("Unapproved credential path")
    payload = bao.request("GET", PREFIX + name)
    return destination_value(payload)[0].decode() if payload else None


def create(bao, name, value):
    previous = read(bao, name)
    if previous is not None:
        if previous != value:
            raise ValueError("Existing credential differs; rotation is not authorized")
        return
    bao.request(
        "POST", PREFIX + name, {"options": {"cas": 0}, "data": {"value": value}}
    )
    if read(bao, name) != value:
        raise ValueError("Credential readback failed")


def verify_project(client, project):
    detail = client.expect("GET", f"/management/v1/projects/{project['id']}")["project"]
    if not detail.get("projectRoleCheck"):
        raise ValueError("Project must enforce user role grants")
    users = client.expect(
        "POST", "/management/v1/users/_search", {"query": {"limit": 1000}}
    ).get("result", [])
    allowed = set()
    found = set()
    for user in users:
        email = user.get("human", {}).get("email", {})
        address = email.get("email", "").lower()
        if address in MEMBERS:
            if address in found or not email.get("isEmailVerified"):
                raise ValueError("Approved emails must be unique and verified")
            found.add(address)
            allowed.add(user["id"])
    if found != MEMBERS:
        raise ValueError("Both approved verified users must exist")
    grants = client.expect(
        "POST",
        "/management/v1/users/grants/_search",
        {
            "query": {"limit": 1000},
            "queries": [{"projectIdQuery": {"projectId": project["id"]}}],
        },
    ).get("result", [])
    if {grant["userId"] for grant in grants} != allowed:
        raise ValueError("Project grants must match exactly the two approved users")
    if any(set(grant.get("roleKeys", [])) != {"admin"} for grant in grants):
        raise ValueError("Approved users require the admin project role")


def main():
    token = os.environ.pop("BAO_TOKEN", "")
    pat = os.environ.pop("ZITADEL_PAT", "")
    if not token or not pat:
        raise ValueError("BAO_TOKEN and ZITADEL_PAT are required")
    bao = OpenBao(os.environ.get("BAO_ADDR", "http://127.0.0.1:18200"), token)
    info = bao.request("GET", "auth/token/lookup-self")["data"]
    if "root" in info.get("policies", []) or not 0 < info.get("ttl", 0) <= 900:
        raise ValueError("Require a short-lived non-root writer")
    try:
        paths = [PREFIX + name for name in NAMES]
        caps = bao.request("POST", "sys/capabilities-self", {"paths": paths})
        if any(
            set(caps.get(path, [])) != {"create", "read", "update"} for path in paths
        ):
            raise ValueError("Writer requires exact create/read/update capabilities")
        client = identity.Client(pat)
        orgs = client.expect(
            "POST", "/admin/v1/orgs/_search", {"query": {"limit": 100}}
        ).get("result", [])
        client.org = next(org["id"] for org in orgs if org["name"] == "TESSERIX")
        projects = client.expect(
            "POST", "/management/v1/projects/_search", {"query": {"limit": 1000}}
        ).get("result", [])
        project = next(
            project for project in projects if project["name"] == "Rocket.Chat"
        )
        verify_project(client, project)
        app_path = f"/management/v1/projects/{project['id']}/apps"
        apps = client.expect(
            "POST", app_path + "/_search", {"query": {"limit": 100}}
        ).get("result", [])
        app = next((app for app in apps if app["name"] == "rocketchat-web"), None)
        if app:
            if read(bao, "zitadel-client-id") != app["oidcConfig"][
                "clientId"
            ] or not read(bao, "zitadel-client-secret"):
                raise ValueError(
                    "Existing app lacks matching stored credentials; explicit recovery is required"
                )
        else:
            if read(bao, "zitadel-client-id") or read(bao, "zitadel-client-secret"):
                raise ValueError("Stored identity credentials already exist")
            app = client.expect(
                "POST",
                app_path + "/oidc",
                {
                    "name": "rocketchat-web",
                    "redirectUris": ["https://rocketchat.tesserix.app/_oauth/zitadel"],
                    "postLogoutRedirectUris": ["https://rocketchat.tesserix.app"],
                    "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
                    "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"],
                    "appType": "OIDC_APP_TYPE_WEB",
                    "authMethodType": "OIDC_AUTH_METHOD_TYPE_BASIC",
                    "accessTokenType": "OIDC_TOKEN_TYPE_BEARER",
                    "devMode": False,
                },
            )
            create(bao, "zitadel-client-secret", app["clientSecret"])
            create(bao, "zitadel-client-id", app["clientId"])
        for name in ("mongodb-root-password", "mongodb-password", "mongodb-keyfile"):
            if read(bao, name) is None:
                value = (
                    base64.b64encode(secrets.token_bytes(96)).decode()
                    if name.endswith("keyfile")
                    else secrets.token_hex(32)
                )
                create(bao, name, value)
        hosts = ",".join(
            f"rocketchat-mongodb-{i}.rocketchat-mongodb.rocketchat.svc.cluster.local:27017"
            for i in range(3)
        )
        password = read(bao, "mongodb-password")
        create(
            bao,
            "mongodb-uri",
            f"mongodb://rocketchat:{password}@{hosts}/rocketchat?replicaSet=rs0&authSource=rocketchat",
        )
        print(
            "Restricted identity and all six OpenBao credentials verified; no values printed"
        )
    finally:
        bao.request("POST", "auth/token/revoke-self", {})


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, StopIteration, MigrationError, OSError):
        sys.exit(
            "Rocket.Chat bootstrap failed; payload withheld. Check grants, access and existing credential state."
        )
