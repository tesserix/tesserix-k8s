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
    log("bootstrap complete")


if __name__ == "__main__":
    sys.exit(main())
