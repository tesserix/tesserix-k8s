"""Reconciles the Zitadel instance branding, policies and admins from Git.

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


def reconcile_lockout_policy(desired):
    """Pin how many failed attempts lock a user out.

    This was Zitadel's own default and nothing declared it, so nothing would
    have noticed it changing — and 0 means unlimited. maxOtpAttempts is the
    only bound on TOTP guessing in this estate: verified against the session
    API on 2026-08-31, a user locks on the 11th wrong code submitted through
    PATCH /v2/sessions/{id}, exactly as the policy says. See values.yaml and
    tesserix-home#445.

    Same replace-not-patch caveat as the login policy: the PUT overwrites the
    whole policy, so undeclared live fields have to be sent back. strip_readonly
    already drops isDefault, which this policy carries while it is unmanaged.

    The declared values are strings because the API returns strings; an integer
    10 would differ from "10" on every run and the job would PUT forever.
    """
    live = get_json("/admin/v1/policies/lockout")["policy"]
    drift = drift_between(desired, live)
    if not drift:
        log("lockout policy: in sync")
        return
    body = strip_readonly(live)
    body.update(desired)
    log(f"lockout policy: updating {sorted(drift)}")
    status, payload = request("PUT", "/admin/v1/policies/lockout", body)
    if status != 200:
        raise SystemExit(f"lockout policy update failed: {status} {payload!r}")


def find_user(identifier):
    """Resolve an admin by login name, or by verified email for federated users.

    An unverified address is whatever the account holder typed, so matching on
    one would let anyone claim IAM_OWNER by setting an email they do not own.

    Capped at 100 users, unpaginated. Verified against the live instance: 9
    users total today, so the headroom is real. But three reconcilers now
    depend on this returning every user — reconcile_admins,
    reconcile_instance_members and reconcile_machine_users — and past 100 the
    call silently returns fewer than all users rather than erroring, so a user
    past the cutoff reads as "does not exist". That would make
    reconcile_machine_users retry a create every run and reconcile_instance_members
    skip a real membership indefinitely.
    Not paginating today; revisit if user count approaches 100.
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


def reconcile_smtp(desired):
    """Assert the SMTP provider without holding its password.

    Email is the only recovery path the break-glass admin has, and a provider
    that is deactivated — or quietly repointed at another host — stops password
    reset with no error anywhere. Nobody finds out until someone is locked out.

    Two behaviours of this endpoint drive the shape of this function, both
    established against the live instance rather than read from a doc:

    - Omitting `password` from the PUT preserves the stored secret. The change
      event carries no password key and mail keeps sending, so a reconciler can
      own the configuration while the credential stays in Secret Manager.
    - `description` is written to the eventstore but **never projected** to the
      read model: a day after it was changed, GET still returned the value set at
      creation. Comparing it would report drift that no write can ever clear, so
      it is sent on update and never treated as drift.
    """
    if not desired:
        return
    config_id = desired["expectedId"]
    status, payload = request("GET", f"/admin/v1/smtp/{config_id}")
    if status != 200:
        raise SystemExit(
            f"smtp config {config_id} not found ({status}); create it once through "
            "/admin/v1/smtp so its password goes straight to Zitadel, then commit the id"
        )
    live = json.loads(payload)["smtpConfig"]

    asserted = ("senderAddress", "senderName", "host", "user", "tls")
    drift = drift_between({key: desired[key] for key in asserted}, live)
    if drift:
        log(f"smtp: reasserting {sorted(drift)}")
        body = {key: desired[key] for key in asserted}
        body["description"] = desired.get("description", "")
        status, payload = request("PUT", f"/admin/v1/smtp/{config_id}", body)
        if status != 200:
            raise SystemExit(f"smtp update failed: {status} {payload!r}")
    else:
        log("smtp: in sync")

    if not desired.get("requireActive"):
        return
    if live.get("state") == "SMTP_CONFIG_ACTIVE":
        log("smtp: active")
        return
    status, payload = request("POST", f"/admin/v1/smtp/{config_id}/_activate", {})
    if status != 200:
        raise SystemExit(f"smtp activation failed: {status} {payload!r}")
    log("smtp: reactivated")


def reconcile_org_login_policy(desired):
    """Overlay declared fields onto an org's custom login policy.

    Orgs with a custom (isDefault=false) policy do not inherit the instance
    policy, so instance-level allowRegister never reaches them. Same
    replace-not-patch caveat as the instance policy: PUT the whole live body
    with only the declared fields overlaid. An org that fell back to the
    default policy is drift between git and the console, not something to
    silently create a custom policy for.
    """
    org = next((item for item in list_orgs() if item["name"] == desired["org"]), None)
    if not org:
        raise SystemExit(f"login policy org {desired['org']!r} does not exist")
    scope = {"x-zitadel-orgid": org["id"]}
    status, payload = request("GET", "/management/v1/policies/login", headers=scope)
    if status != 200:
        raise SystemExit(f"login policy read for {desired['org']} failed: {status} {payload!r}")
    live = json.loads(payload)["policy"]
    if live.get("isDefault"):
        raise SystemExit(
            f"org {desired['org']} inherits the instance login policy; resolve which "
            "policy the org should run before asserting fields on it here"
        )
    drift = drift_between(desired["policy"], live)
    if not drift:
        log(f"login policy {desired['org']}: in sync")
        return
    body = strip_readonly(live)
    body.update(desired["policy"])
    log(f"login policy {desired['org']}: updating {sorted(drift)}")
    status, payload = request("PUT", "/management/v1/policies/login", body, headers=scope)
    if status != 200:
        raise SystemExit(f"login policy update for {desired['org']} failed: {status} {payload!r}")


def reconcile_org_idps(desired_idps):
    """Assert an org's IdP connector without ever holding its client secret.

    Only the secret is off-limits; the behaviour flags are reconciled, because
    they are exactly what gets flipped in the console. `isAutoUpdate` in
    particular rewrites a linked user's profile from the provider's claims on
    every federated sign-in, which reverts any display name edited here — it
    looked like a broken profile form until the event log showed the overwrite.

    Omitting `clientSecret` from the update is safe and deliberate: Zitadel only
    re-encrypts the secret when the field is present, so the change event carries
    no secret and the stored value survives. Sending an empty string would blank
    it. That is the distinction an earlier revision of docs/zitadel.md missed.

    Anything that cannot be fixed without the secret fails the run instead: a
    missing provider, an unexpected ID, or a different client ID all mean the
    live trust anchor is not the one git describes, and quietly repointing users'
    federated identities is worse than stopping.
    """
    for desired in desired_idps:
        org = next((item for item in list_orgs() if item["name"] == desired["org"]), None)
        if not org:
            raise SystemExit(f"idp org {desired['org']!r} does not exist")
        scope = {"x-zitadel-orgid": org["id"]}
        name = desired["name"]

        status, payload = request(
            "POST", "/management/v1/idps/templates/_search", {"query": {"limit": 100}}, headers=scope
        )
        if status != 200:
            raise SystemExit(f"idp search in {desired['org']} failed: {status} {payload!r}")
        matches = [item for item in json.loads(payload).get("result", []) if item["name"] == name]
        if len(matches) != 1:
            raise SystemExit(
                f"idp {name!r} must exist exactly once in {desired['org']}; create it once "
                "through the console so its one-time secret goes straight to Zitadel"
            )
        live = matches[0]
        if live["id"] != desired["expectedId"]:
            raise SystemExit(
                f"idp {name!r} ID {live['id']} does not match the committed "
                f"{desired['expectedId']}; user links point at a provider git does not describe"
            )

        live_client_id = live["config"]["google"].get("clientId")
        if live_client_id != desired["clientId"]:
            raise SystemExit(
                f"idp {name!r} client ID drifted to {live_client_id!r}; repointing it needs the "
                "new client's secret, which this reconciler deliberately does not hold"
            )

        drift = drift_between(desired["options"], live["config"].get("options", {}))
        if drift:
            log(f"idp {name}: reasserting {sorted(drift)}")
            status, payload = request(
                "PUT",
                f"/management/v1/idps/google/{live['id']}",
                {
                    "name": name,
                    "clientId": desired["clientId"],
                    "scopes": desired["scopes"],
                    "providerOptions": desired["options"],
                },
                headers=scope,
            )
            if status != 200:
                raise SystemExit(f"idp {name!r} update failed: {status} {payload!r}")
        else:
            log(f"idp {name}: in sync")

        # A provider the login policy does not reference is live but invisible:
        # no button on the login page, and no error anywhere saying why.
        status, payload = request("GET", "/management/v1/policies/login", headers=scope)
        if status != 200:
            raise SystemExit(f"login policy read for {desired['org']} failed: {status} {payload!r}")
        bound = {item.get("idpId") for item in json.loads(payload)["policy"].get("idps", [])}
        if live["id"] in bound:
            log(f"idp {name}: bound to the {desired['org']} login policy")
            continue
        status, payload = request(
            "POST", "/management/v1/policies/login/idps", {"idpId": live["id"]}, headers=scope
        )
        if status != 200:
            raise SystemExit(f"idp {name!r} login policy binding failed: {status} {payload!r}")
        log(f"idp {name}: bound to the {desired['org']} login policy")


def reconcile_machine_users(machine_users):
    """Create a declared machine user if it does not exist yet.

    Every machine user previously had to be created by hand in the console,
    and nothing recorded why it existed. `description` is required here for
    exactly that reason: it is the only field that tells a future reader what
    the account is for, and this estate has repeatedly been bitten by correct
    things declared nowhere (svc-onboarding's IAM_OWNER grant, for one — see
    assert_machine_iam_owners_allowlisted).

    Runs before reconcile_platform_project so a machine user created here can
    be granted project roles in the same pass, rather than needing two runs.

    The credential itself (a PAT or machine key) is never handled here: it can
    only be read once at issue time, so it still goes into Secret Manager by
    hand after this creates the user. See docs/zitadel.md "What is not in git".
    """
    for machine in machine_users:
        if not machine.get("description"):
            raise SystemExit(
                f"machine user {machine['username']}: description is required, "
                "so a future reader knows why this account exists"
            )
        org = next((item for item in list_orgs() if item["name"] == machine["org"]), None)
        if not org:
            raise SystemExit(f"machine user org {machine['org']!r} does not exist")
        scope = {"x-zitadel-orgid": org["id"]}

        user_id = find_user(machine["username"])
        if user_id:
            log(f"machine user {machine['username']}: in sync")
            continue

        status, payload = request(
            "POST",
            "/management/v1/users/machine",
            {
                "userName": machine["username"],
                "name": machine["name"],
                "description": machine["description"],
                "accessTokenType": machine["accessTokenType"],
            },
            headers=scope,
        )
        if status != 200:
            raise SystemExit(f"machine user {machine['username']} create failed: {status} {payload!r}")
        log(f"machine user {machine['username']}: created")


def reconcile_instance_members(instance_members, admins, machine_logins=()):
    """Grant or update instance-level memberships with an explicit role list.

    reconcile_admins hardcodes IAM_OWNER for desired.admins; this reconciles
    desired.instanceMembers, where the caller states the roles explicitly. The
    two must never target the same login — two reconcilers writing different
    roles to one membership would flap every 30 minutes, which is worse than
    leaving the grant as a manual step. That is checked up front, against the
    raw login lists, before either side makes an API call.

    machine_logins is the set of usernames reconcile_machine_users has already
    created in this same pass (it must run first — see main()). A login not
    resolvable by find_user is not automatically forgivable the way an
    unregistered human admin is: a human genuinely may not have signed in yet,
    but a machine user with no first-sign-in concept either exists because
    reconcile_machine_users just created it, or its declaration here is wrong
    (a typo, or a declaration order bug like tesserix-home#211). So a login in
    machineUsers that still doesn't resolve fails the run naming the login,
    instead of silently deferring the grant to the next scheduled run 30
    minutes later.
    """
    overlap = sorted(set(admins) & {member["login"] for member in instance_members})
    if overlap:
        raise SystemExit(
            f"login(s) {', '.join(overlap)} appear in both desired.admins and "
            "desired.instanceMembers; each login must be reconciled by exactly one of them"
        )

    live = {
        member["userId"]: member.get("roles", [])
        for member in json.loads(
            request("POST", "/admin/v1/members/_search", {"query": {"limit": 100}})[1]
        ).get("result", [])
    }
    for member in instance_members:
        user_id = find_user(member["login"])
        if not user_id:
            if member["login"] in machine_logins:
                raise SystemExit(
                    f"instance member {member['login']}: declared in desired.machineUsers "
                    "but still not resolvable after reconcile_machine_users ran; this is a "
                    "bug (ordering or a typo), not a not-yet-signed-in user"
                )
            log(
                f"instance member {member['login']}: no such user yet "
                "(human admins only exist after their first sign-in), skipping"
            )
            continue
        wanted_roles = sorted(member["roles"])
        current_roles = sorted(live.get(user_id, []))
        if current_roles == wanted_roles:
            log(f"instance member {member['login']}: in sync")
            continue
        if user_id in live:
            status, payload = request("PUT", f"/admin/v1/members/{user_id}", {"roles": wanted_roles})
        else:
            status, payload = request("POST", "/admin/v1/members", {"userId": user_id, "roles": wanted_roles})
        if status != 200:
            raise SystemExit(f"instance member {member['login']} grant failed: {status} {payload!r}")
        log(f"instance member {member['login']}: roles reconciled")


def assert_machine_iam_owners_allowlisted(allowed):
    """Fail the run if an un-declared machine user holds instance-wide IAM_OWNER.

    A live query against the instance found two: iam-admin, this reconciler's
    own credential, and svc-onboarding, documented only in
    docs/onboarding-api.md and absent from every identity-facing list. A
    machine user with IAM_OWNER can create and delete organizations, users and
    grants across the whole platform — that is not something a new grant
    should acquire silently.

    Reports rather than revokes, same precedent as assert_reserved_org_clean:
    revoking a service account's own instance role from underneath it can take
    its callers down, and that is a decision for whoever put the grant there,
    not for a scheduled job.

    No extra API call: /admin/v1/members/_search already returns userType,
    preferredLoginName and userId per member, confirmed against the live
    instance.
    """
    status, payload = request("POST", "/admin/v1/members/_search", {"query": {"limit": 100}})
    if status != 200:
        raise SystemExit(f"instance member search failed: {status} {payload!r}")
    allowed_set = set(allowed)
    strays = sorted(
        member.get("preferredLoginName") or member.get("userId")
        for member in json.loads(payload).get("result", [])
        if member.get("userType") == "TYPE_MACHINE"
        and "IAM_OWNER" in member.get("roles", [])
        and member.get("preferredLoginName") not in allowed_set
    )
    if strays:
        raise SystemExit(
            f"machine user(s) hold IAM_OWNER without being in desired.allowedIamOwnerMachines: "
            f"{', '.join(strays)}. Add them with a reason, or revoke the grant."
        )
    log("machine IAM_OWNER holders: allowlisted")


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
            if "grantTypes" in wanted:
                actual["grantTypes"] = sorted(live.get("grantTypes", []))
                expected["grantTypes"] = sorted(wanted["grantTypes"])
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
    grant_groups = (
        ("user", desired.get("humanGrants", [])),
        ("machine", desired.get("machineGrants", [])),
    )
    for principal, configured_grants in grant_groups:
        for grant in configured_grants:
            user_id = find_user(grant["login"])
            if not user_id:
                if principal == "machine":
                    raise SystemExit(
                        f"platform project machine {grant['login']}: no such user"
                    )
                log(
                    f"platform project {principal} {grant['login']}: "
                    "no such verified user, skipping"
                )
                continue
            live = next(
                (
                    item
                    for item in grants
                    if item.get("userId") == user_id
                    and item.get("projectId") == project_id
                ),
                None,
            )
            wanted_roles = sorted(grant["roles"])
            if live and sorted(live.get("roleKeys", [])) == wanted_roles:
                log(f"platform project {principal} {grant['login']}: in sync")
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
                    f"platform project grant for {grant['login']} failed: "
                    f"{status} {payload!r}"
                )
            log(
                f"platform project {principal} {grant['login']}: roles reconciled"
            )


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
    reconcile_lockout_policy(desired["lockoutPolicy"])
    reconcile_admins(desired["admins"])
    # Before reconcile_instance_members: a login can be declared in both
    # machineUsers and instanceMembers (create a reader, grant it a scoped
    # role), and that grant must land in the same pass rather than waiting
    # for a machine user created this run to be visible on the next one.
    machine_users = desired.get("machineUsers", [])
    reconcile_machine_users(machine_users)
    reconcile_instance_members(
        desired.get("instanceMembers", []),
        desired["admins"],
        machine_logins={machine["username"] for machine in machine_users},
    )
    reconcile_default_org(desired["defaultOrg"])
    reconcile_org_branding(desired["selfBrandedOrgs"])
    reconcile_smtp(desired.get("smtp"))
    for policy in desired.get("orgLoginPolicies", []):
        reconcile_org_login_policy(policy)
    reconcile_org_idps(desired.get("idps", []))
    # Also before platform projects: a machine user created above can be
    # granted project roles in the same pass.
    for project in desired.get("platformProjects", []):
        reconcile_platform_project(project)
    # Last: a stray project or an unlisted IAM_OWNER is a report, and must not
    # stop branding converging.
    assert_reserved_org_clean(desired["reservedOrg"]["name"], desired["reservedOrg"]["allowedProjects"])
    assert_machine_iam_owners_allowlisted(desired.get("allowedIamOwnerMachines", []))
    log("bootstrap complete")


if __name__ == "__main__":
    sys.exit(main())
