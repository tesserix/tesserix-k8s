"""One-shot migration: pre-provision Keycloak users into per-product GIP tenants.

Background
----------
Until 2026-05-12 our customer-facing and internal admin auth was served by
Keycloak (two deployments: identity-customer + identity-internal, sharing
the global CNPG cluster). We are decommissioning them in favour of Google
Identity Platform (GIP) — one tenant per product (not one big shared
tenant), so each product's user base is isolated:

    Keycloak realm        ->  GIP tenant            class
    --------------------------------------------------------
    blog                  ->  Blog-znj8b            customer
    fanzone               ->  Fanzone-ut25f         customer
    gameverse             ->  Gameverse-ftf7f       customer
    homechef              ->  HomeChef-gufzu        customer
    devai + devai-sre     ->  DevAI-1mh9c           admin
    stockpilot            ->  StockPilot-37yur      admin
    social-scrapper       ->  Social-tuhg7          admin (pre-existing)
    tesserix-internal     ->  Platform-9bu14        admin (pre-existing)
                              MP-Customer-39opy     mark8ly customer (untouched)
                              MP-Internal-e986p     mark8ly admin (untouched)

Every user in scope authenticates via Google (and one via Facebook in
homechef). There is essentially zero local-password traffic, so the
migration is pure email + IdP-link, NOT a hash import.

What this script does
---------------------
1. Reads /tmp/keycloak-users-export.json (emitted by the discovery query)
2. Reads /tmp/gip-tenants.json (emitted by create_product_tenants.py),
   the canonical realm -> tenant_id map.
3. For each (realm, user) row: routes the user into their product's
   tenant. The SAME email can validly appear in multiple tenants — e.g.
   samyak.rout@gmail.com is a fanzone customer AND a stockpilot internal
   user — because each tenant has its own user namespace. Within a single
   tenant emails are unique, so we still dedupe per-tenant.
4. For each (tenant, email): get_user_by_email -> update, or create.
   email_verified is set to True so first social-login auto-links the
   Google/Facebook identity to the record (same UX as Keycloak's
   idp-auto-link flow we already run today).
5. Admin allow-list enforcement: on admin-class tenants, the 3 emails in
   ADMIN_EMAILS get the {"admin": true} custom claim. Customer-class
   tenants never have admin claims.

The script is idempotent. Re-running is a no-op for users already in the
target shape. Service accounts (username starting `service-account-`) and
master-realm rows are skipped at discovery time.

Auth
----
Application Default Credentials. Caller must hold roles/firebaseauth.admin
or roles/owner on tesseracthub-480811.
"""

from __future__ import annotations

import json
import os
import sys
from collections import defaultdict
from dataclasses import dataclass, field

import firebase_admin
from firebase_admin import auth, credentials, tenant_mgt

PROJECT_ID = "tesseracthub-480811"

ADMIN_EMAILS = {
    "samyak.rout@gmail.com",
    "unidevidp@gmail.com",
    "mahesh.sangawar@gmail.com",
}

EXPORT_PATH = os.environ.get("KEYCLOAK_EXPORT_JSON", "/tmp/keycloak-users-export.json")
TENANTS_PATH = os.environ.get("GIP_TENANTS_JSON", "/tmp/gip-tenants.json")


@dataclass
class TargetUser:
    email: str
    display_name: str = ""
    realms: set[str] = field(default_factory=set)
    idps: set[str] = field(default_factory=set)


def aggregate(rows: list[dict], realm_to_tenant: dict[str, str]) -> dict[str, dict[str, TargetUser]]:
    """Bucket Keycloak rows -> {tenant_id: {email: TargetUser}}."""
    out: dict[str, dict[str, TargetUser]] = defaultdict(dict)
    for r in rows:
        realm = r["realm"]
        tenant = realm_to_tenant.get(realm)
        if not tenant:
            print(f"  [skip] realm {realm!r} has no tenant mapping", file=sys.stderr)
            continue
        email = (r.get("email") or "").strip().lower()
        if not email:
            continue
        if r.get("username", "").startswith("service-account-"):
            continue
        rec = out[tenant].setdefault(email, TargetUser(email=email))
        name = " ".join(p for p in [r.get("first_name", "").strip(), r.get("last_name", "").strip()] if p)
        if name and not rec.display_name:
            rec.display_name = name
        rec.realms.add(realm)
        for idp in r.get("idps", []):
            rec.idps.add(idp)
    return out


def upsert_user(tenant_client, target: TargetUser, is_admin_tenant: bool) -> str:
    """Return action: 'created' | 'updated' | 'unchanged'."""
    want_admin = is_admin_tenant and target.email in ADMIN_EMAILS

    try:
        user = tenant_client.get_user_by_email(target.email)
        updates: dict[str, object] = {}
        if target.display_name and (user.display_name or "") != target.display_name:
            updates["display_name"] = target.display_name
        if not user.email_verified:
            updates["email_verified"] = True
        if updates:
            tenant_client.update_user(user.uid, **updates)
            action = "updated"
        else:
            action = "unchanged"
        existing_claims = user.custom_claims or {}
        if want_admin and existing_claims.get("admin") is not True:
            tenant_client.set_custom_user_claims(
                user.uid, {**existing_claims, "admin": True}
            )
            action = "updated"
        elif (not want_admin) and existing_claims.get("admin") is True:
            cleaned = {k: v for k, v in existing_claims.items() if k != "admin"}
            tenant_client.set_custom_user_claims(user.uid, cleaned or None)
            action = "updated"
        return action

    except auth.UserNotFoundError:
        kwargs = {"email": target.email, "email_verified": True}
        if target.display_name:
            kwargs["display_name"] = target.display_name
        user = tenant_client.create_user(**kwargs)
        if want_admin:
            tenant_client.set_custom_user_claims(user.uid, {"admin": True})
        return "created"


def main() -> int:
    if not os.path.exists(EXPORT_PATH):
        print(f"[fatal] export file not found: {EXPORT_PATH}", file=sys.stderr)
        return 2
    if not os.path.exists(TENANTS_PATH):
        print(f"[fatal] tenants file not found: {TENANTS_PATH}", file=sys.stderr)
        return 2

    rows = json.load(open(EXPORT_PATH))
    tenants_cfg = json.load(open(TENANTS_PATH))
    realm_to_tenant: dict[str, str] = tenants_cfg["realm_to_tenant"]
    tenant_meta: dict[str, dict] = tenants_cfg["tenant_meta"]

    print(f"[info] loaded {len(rows)} user-realm rows from {EXPORT_PATH}")
    print(f"[info] {len(realm_to_tenant)} realms mapped across {len(tenant_meta)} tenants")

    buckets = aggregate(rows, realm_to_tenant)

    app = firebase_admin.initialize_app(
        credentials.ApplicationDefault(), {"projectId": PROJECT_ID}
    )

    results: dict[str, dict[str, int]] = {}
    for tenant_id in sorted(buckets):
        users = buckets[tenant_id]
        meta = tenant_meta[tenant_id]
        is_admin = meta["class"] == "admin"
        client = tenant_mgt.auth_for_tenant(tenant_id, app=app)
        counts = {"created": 0, "updated": 0, "unchanged": 0, "failed": 0}
        print(f"\n--- {tenant_id}  display={meta['display_name']}  class={meta['class']}  ({len(users)} unique users) ---")
        for email, target in sorted(users.items()):
            try:
                action = upsert_user(client, target, is_admin)
                counts[action] += 1
                tag = "   " if action == "unchanged" else action[:3].upper()
                print(f"  [{tag}] {email:35} name=\"{target.display_name}\" "
                      f"realms={sorted(target.realms)} idps={sorted(target.idps)}")
            except Exception as exc:
                counts["failed"] += 1
                print(f"  [ERR] {email}: {exc}", file=sys.stderr)
        results[tenant_id] = counts

    print("\n=== summary ===")
    for t, c in results.items():
        print(f"  {t:25} {c}")
    failed = sum(c["failed"] for c in results.values())
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
