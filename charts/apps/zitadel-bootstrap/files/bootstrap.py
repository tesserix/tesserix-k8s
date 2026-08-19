"""Reconciles the Zitadel instance branding, login policy and admins from Git.

Runs on a schedule, so every step is idempotent: it compares desired state to
live state and only writes on a difference. Assets are compared by content
hash — re-uploading unconditionally would mint a new asset URL each run and
invalidate every cached logo.
"""

import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

API = os.environ["ZITADEL_API"]
HOST = os.environ["ZITADEL_HOST"]
CONFIG_PATH = os.environ.get("CONFIG_PATH", "/config/desired.json")
ASSET_DIR = os.environ.get("ASSET_DIR", "/assets")
PAT_PATH = os.environ.get("PAT_PATH", "/pat/pat")

with open(PAT_PATH) as fh:
    TOKEN = fh.read().strip()


def request(method, path, body=None, headers=None, raw=None, content_type=None):
    url = f"{API}{path}"
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method)
    # Zitadel resolves the instance from the Host header; the in-cluster
    # service name matches no instance domain and returns "Instance not found".
    req.add_header("Host", HOST)
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("Content-Type", content_type or "application/json")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read()


def get_json(path):
    status, payload = request("GET", path)
    if status != 200:
        raise SystemExit(f"GET {path} failed: {status} {payload!r}")
    return json.loads(payload)


def log(message):
    print(message, flush=True)


def drift_between(desired, live):
    """Fields where live differs from desired.

    Zitadel serialises protobuf defaults by omission, so a field we want set to
    false or "" comes back absent rather than false. Comparing against the live
    dict directly reports drift on every run and the job never converges.
    """
    return {
        key: value for key, value in desired.items()
        if live.get(key, type(value)() if isinstance(value, (bool, str, int)) else None) != value
    }


def strip_readonly(policy):
    """Drop server-owned fields: metadata, and the asset URLs the assets API sets."""
    return {
        key: value for key, value in policy.items()
        if key not in ("details", "isDefault") and not key.endswith(("Url", "UrlDark"))
    }


def reconcile_label_policy(desired):
    live = get_json("/admin/v1/policies/label")["policy"]
    drift = drift_between(desired, live)
    if not drift:
        log("label policy: in sync")
        return False
    # PUT replaces the policy, so undeclared fields have to be sent back.
    body = strip_readonly(live)
    body.update(desired)
    log(f"label policy: updating {sorted(drift)}")
    status, payload = request("PUT", "/admin/v1/policies/label", body)
    if status != 200:
        raise SystemExit(f"label policy update failed: {status} {payload!r}")
    return True


def reconcile_asset(name, filename):
    """Upload a logo only when its bytes differ from the one being served."""
    path = os.path.join(ASSET_DIR, filename)
    with open(path, "rb") as fh:
        wanted = fh.read()

    status, live = request("GET", f"/assets/v1/instance/policy/label/{name}")
    if status == 200 and hashlib.sha256(live).digest() == hashlib.sha256(wanted).digest():
        log(f"asset {name}: in sync")
        return False

    boundary = uuid.uuid4().hex
    body = b"".join([
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode(),
        b"Content-Type: image/png\r\n\r\n",
        wanted,
        f"\r\n--{boundary}--\r\n".encode(),
    ])
    status, payload = request(
        "POST",
        f"/assets/v1/instance/policy/label/{name}",
        raw=body,
        content_type=f"multipart/form-data; boundary={boundary}",
    )
    if status not in (200, 201):
        raise SystemExit(f"asset {name} upload failed: {status} {payload!r}")
    log(f"asset {name}: uploaded {len(wanted)} bytes")
    return True


def activate_label_policy():
    status, payload = request("POST", "/admin/v1/policies/label/_activate", {})
    if status != 200:
        raise SystemExit(f"label policy activation failed: {status} {payload!r}")
    log("label policy: activated")


def reconcile_login_policy(desired):
    """Overlay the declared fields onto the live policy and PUT the whole thing.

    The endpoint replaces the policy rather than patching it, so sending only
    the declared fields would reset the lifetimes and redirect URI this chart
    deliberately does not manage.
    """
    live = get_json("/admin/v1/policies/login")["policy"]
    drift = drift_between(desired, live)
    if not drift:
        log("login policy: in sync")
        return
    body = strip_readonly(live)
    body.update(desired)
    log(f"login policy: updating {sorted(drift)}")
    status, payload = request("PUT", "/admin/v1/policies/login", body)
    if status != 200:
        raise SystemExit(f"login policy update failed: {status} {payload!r}")


def find_user(identifier):
    """Resolve an admin by login name, or by verified email for federated users.

    An unverified address is whatever the account holder typed, so matching on
    one would let anyone claim IAM_OWNER by setting an email they do not own.
    """
    status, payload = request("POST", "/v2/users", {"query": {"limit": 100}})
    if status != 200:
        raise SystemExit(f"user search failed: {status} {payload!r}")
    wanted = identifier.lower()
    for user in json.loads(payload).get("result", []):
        if user.get("username", "").lower() == wanted:
            return user["userId"]
        email = user.get("human", {}).get("email", {})
        if email.get("isVerified") and email.get("email", "").lower() == wanted:
            return user["userId"]
    return None


def reconcile_admins(admins):
    live = {
        member["userId"]: member.get("roles", [])
        for member in json.loads(request("POST", "/admin/v1/members/_search", {"query": {"limit": 100}})[1]).get("result", [])
    }
    for login_name in admins:
        user_id = find_user(login_name)
        if not user_id:
            # A Google-federated admin only exists after their first sign-in.
            log(f"admin {login_name}: no such user yet, skipping")
            continue
        if "IAM_OWNER" in live.get(user_id, []):
            log(f"admin {login_name}: in sync")
            continue
        status, payload = request("POST", "/admin/v1/members", {"userId": user_id, "roles": ["IAM_OWNER"]})
        if status != 200:
            raise SystemExit(f"admin {login_name} grant failed: {status} {payload!r}")
        log(f"admin {login_name}: granted IAM_OWNER")


def list_orgs():
    status, payload = request("POST", "/admin/v1/orgs/_search", {"query": {"limit": 100}})
    if status != 200:
        raise SystemExit(f"org search failed: {status} {payload!r}")
    return json.loads(payload).get("result", [])


def reconcile_default_org(name):
    """Point new users and registrations at TESSERIX rather than the ZITADEL org.

    The ZITADEL org cannot be deleted — it owns the console project and the
    break-glass admin — so demoting it is as far as this goes. See docs/zitadel.md.
    """
    wanted = next((org for org in list_orgs() if org["name"] == name), None)
    if not wanted:
        raise SystemExit(f"default org {name!r} does not exist")
    current = get_json("/admin/v1/orgs/default")["org"]["id"]
    if current == wanted["id"]:
        log(f"default org: {name} in sync")
        return
    status, payload = request("PUT", f"/admin/v1/orgs/default/{wanted['id']}", {})
    if status != 200:
        raise SystemExit(f"default org update failed: {status} {payload!r}")
    log(f"default org: promoted {name}")


def reconcile_org_branding(self_branded):
    """Reset any org that has quietly overridden the instance skin.

    An org-level label policy shadows the instance one for every login scoped to
    that org, so an override is how the platform look silently diverges. Orgs
    named in selfBrandedOrgs supply their own branding by design and are skipped.
    """
    for org in list_orgs():
        if org["name"] in self_branded:
            log(f"org branding {org['name']}: self-branded, skipping")
            continue
        scope = {"x-zitadel-orgid": org["id"]}
        status, payload = request("GET", "/management/v1/policies/label", headers=scope)
        if status != 200:
            raise SystemExit(f"org {org['name']} label policy read failed: {status} {payload!r}")
        if json.loads(payload)["policy"].get("isDefault"):
            log(f"org branding {org['name']}: inheriting instance skin")
            continue
        status, payload = request("DELETE", "/management/v1/policies/label", headers=scope)
        if status != 200:
            raise SystemExit(f"org {org['name']} label policy reset failed: {status} {payload!r}")
        log(f"org branding {org['name']}: reset to the instance skin")


def reconcile_platform_project(desired):
    """Reconcile a platform resource-server project without managing secrets.

    Project IDs are JWT audiences embedded in gateway policy. A different ID
    must stop reconciliation rather than silently issuing tokens the gateway
    will reject. Machine client secrets remain one-time credentials in Secret
    Manager and are deliberately outside this periodic reconciler.
    """
    org = next((item for item in list_orgs() if item["name"] == desired["org"]), None)
    if not org:
        raise SystemExit(f"platform project org {desired['org']!r} does not exist")
    scope = {"x-zitadel-orgid": org["id"]}

    status, payload = request(
        "POST",
        "/management/v1/projects/_search",
        {"query": {"limit": 100}},
        headers=scope,
    )
    if status != 200:
        raise SystemExit(f"platform project search failed: {status} {payload!r}")
    project = next(
        (item for item in json.loads(payload).get("result", []) if item["name"] == desired["name"]),
        None,
    )
    if not project:
        raise SystemExit(
            f"platform project {desired['name']!r} is missing; create it once and "
            "commit its ID as expectedId before enabling gateway audiences"
        )
    if project["id"] != desired["expectedId"]:
        raise SystemExit(
            f"platform project {desired['name']!r} ID {project['id']} does not match "
            f"the committed JWT audience {desired['expectedId']}"
        )
    project_id = project["id"]

    wanted_apps = desired.get("oidcApps", [])
    if wanted_apps:
        status, payload = request(
            "POST",
            f"/management/v1/projects/{project_id}/apps/_search",
            {"query": {"limit": 100}},
            headers=scope,
        )
        if status != 200:
            raise SystemExit(
                f"platform project application search failed: {status} {payload!r}"
            )
        live_apps = json.loads(payload).get("result", [])
        for wanted in wanted_apps:
            matches = [item for item in live_apps if item["name"] == wanted["name"]]
            if len(matches) != 1:
                raise SystemExit(
                    f"platform OIDC application {wanted['name']!r} must exist exactly once; "
                    "create it through the identity onboarding runbook"
                )
            status, payload = request(
                "GET",
                f"/management/v1/projects/{project_id}/apps/{matches[0]['id']}",
                headers=scope,
            )
            if status != 200:
                raise SystemExit(
                    f"platform OIDC application {wanted['name']!r} read failed: "
                    f"{status} {payload!r}"
                )
            live = json.loads(payload)["app"].get("oidcConfig", {})
            actual = {
                "redirectUris": sorted(live.get("redirectUris", [])),
                "postLogoutRedirectUris": sorted(
                    live.get("postLogoutRedirectUris", [])
                ),
                "appType": live.get("appType", "OIDC_APP_TYPE_WEB"),
                "authMethodType": live.get(
                    "authMethodType", "OIDC_AUTH_METHOD_TYPE_BASIC"
                ),
            }
            expected = {
                "redirectUris": sorted(wanted["redirectUris"]),
                "postLogoutRedirectUris": sorted(
                    wanted["postLogoutRedirectUris"]
                ),
                "appType": wanted.get("appType", "OIDC_APP_TYPE_WEB"),
                "authMethodType": wanted.get(
                    "authMethodType", "OIDC_AUTH_METHOD_TYPE_BASIC"
                ),
            }
            if actual != expected:
                raise SystemExit(
                    f"platform OIDC application {wanted['name']!r} configuration drifted; "
                    "reconcile it through the identity onboarding runbook"
                )
            login_base_uri = wanted.get("loginBaseUri")
            if not login_base_uri:
                log(f"platform OIDC application {wanted['name']}: in sync")
                continue
            connect_headers = {**scope, "Connect-Protocol-Version": "1"}
            status, payload = request(
                "POST",
                "/zitadel.application.v2.ApplicationService/GetApplication",
                {"applicationId": matches[0]["id"]},
                headers=connect_headers,
            )
            if status != 200:
                raise SystemExit(
                    f"platform OIDC application {wanted['name']!r} login version read "
                    f"failed: {status} {payload!r}"
                )
            login_version = (
                json.loads(payload)["application"]
                .get("oidcConfiguration", {})
                .get("loginVersion", {})
            )
            actual_base_uri = login_version.get("loginV2", {}).get("baseUri")
            if actual_base_uri == login_base_uri:
                log(f"platform OIDC application {wanted['name']}: in sync")
                continue
            status, payload = request(
                "POST",
                "/zitadel.application.v2.ApplicationService/UpdateApplication",
                {
                    "applicationId": matches[0]["id"],
                    "projectId": project_id,
                    "oidcConfiguration": {
                        "loginVersion": {
                            "loginV2": {"baseUri": login_base_uri}
                        }
                    },
                },
                headers=connect_headers,
            )
            if status != 200:
                raise SystemExit(
                    f"platform OIDC application {wanted['name']!r} login version update "
                    f"failed: {status} {payload!r}"
                )
            log(f"platform OIDC application {wanted['name']}: enabled Login V2")

    roles_path = f"/management/v1/projects/{project_id}/roles/_search"
    status, payload = request("POST", roles_path, {"query": {"limit": 100}}, headers=scope)
    if status != 200:
        raise SystemExit(f"platform project role search failed: {status} {payload!r}")
    live_roles = {item["key"]: item for item in json.loads(payload).get("result", [])}
    for role in desired.get("roles", []):
        if role["key"] in live_roles:
            log(f"platform project {desired['name']} role {role['key']}: in sync")
            continue
        status, payload = request(
            "POST",
            f"/management/v1/projects/{project_id}/roles",
            {
                "roleKey": role["key"],
                "displayName": role["displayName"],
                "group": role.get("group", ""),
            },
            headers=scope,
        )
        if status != 200:
            raise SystemExit(
                f"platform project role {role['key']} create failed: {status} {payload!r}"
            )
        log(f"platform project {desired['name']} role {role['key']}: created")

    status, payload = request(
        "POST",
        "/management/v1/users/grants/_search",
        {"query": {"limit": 100}},
        headers=scope,
    )
    if status != 200:
        raise SystemExit(f"platform project grant search failed: {status} {payload!r}")
    grants = json.loads(payload).get("result", [])
    for grant in desired.get("humanGrants", []):
        user_id = find_user(grant["login"])
        if not user_id:
            log(f"platform project user {grant['login']}: no such verified user, skipping")
            continue
        live = next(
            (
                item
                for item in grants
                if item.get("userId") == user_id and item.get("projectId") == project_id
            ),
            None,
        )
        wanted_roles = sorted(grant["roles"])
        if live and sorted(live.get("roleKeys", [])) == wanted_roles:
            log(f"platform project user {grant['login']}: in sync")
            continue
        if live:
            method = "PUT"
            path = f"/management/v1/users/{user_id}/grants/{live['id']}"
            body = {"roleKeys": wanted_roles}
        else:
            method = "POST"
            path = f"/management/v1/users/{user_id}/grants"
            body = {"projectId": project_id, "roleKeys": wanted_roles}
        status, payload = request(method, path, body, headers=scope)
        if status != 200:
            raise SystemExit(
                f"platform project grant for {grant['login']} failed: {status} {payload!r}"
            )
        log(f"platform project user {grant['login']}: roles reconciled")


def assert_reserved_org_clean(name, allowed):
    """Fail if a product project has been created in the reserved ZITADEL org.

    Reports rather than deletes: a project holds live OIDC clients, and removing
    one takes an application's logins down. Moving it out is a manual cutover —
    docs/zitadel.md "Moving a project between orgs".
    """
    org = next((org for org in list_orgs() if org["name"] == name), None)
    if not org:
        log(f"reserved org {name}: does not exist, nothing to check")
        return
    status, payload = request("POST", "/management/v1/projects/_search", {"query": {"limit": 100}},
                              headers={"x-zitadel-orgid": org["id"]})
    if status != 200:
        raise SystemExit(f"reserved org {name} project search failed: {status} {payload!r}")
    strays = sorted(p["name"] for p in json.loads(payload).get("result", []) if p["name"] not in allowed)
    if strays:
        raise SystemExit(
            f"reserved org {name} holds non-platform projects: {', '.join(strays)}. "
            f"Products belong in the default org; see docs/zitadel.md."
        )
    log(f"reserved org {name}: clean")


def main():
    with open(CONFIG_PATH) as fh:
        desired = json.load(fh)

    touched = reconcile_label_policy(desired["labelPolicy"])
    for name, filename in desired["assets"].items():
        touched = reconcile_asset(name, filename) or touched
    if touched:
        activate_label_policy()

    reconcile_login_policy(desired["loginPolicy"])
    reconcile_admins(desired["admins"])
    reconcile_default_org(desired["defaultOrg"])
    reconcile_org_branding(desired["selfBrandedOrgs"])
    for project in desired.get("platformProjects", []):
        reconcile_platform_project(project)
    # Last: a stray project is a report, and must not stop branding converging.
    assert_reserved_org_clean(desired["reservedOrg"]["name"], desired["reservedOrg"]["allowedProjects"])
    log("bootstrap complete")


if __name__ == "__main__":
    sys.exit(main())
