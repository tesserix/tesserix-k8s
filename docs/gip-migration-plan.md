# Migration: Customer Keycloak → Google Identity Platform (GIP)

**Goal.** Retire `identity-customer` and `identity-internal` Keycloaks. Move customer login (fanzone, homechef, future products) and admin login (mark8ly admin, devai, homechef admin, etc.) to the GIP setup that already exists in this GCP project. Lock admin access to a fixed allow-list.

**Why now.** The customer Keycloak's Postgres pool has been failing since 05:23 UTC today, taking Google IdP callbacks with it. Beyond this outage, the realm-import job has documented gotchas (Google client-id substitution, `idp-auto-link` flow exec ordering, partialImport SKIP traps), the `db-backup-and-restore` operator's customer-realm bootstrap is fragile, and the multi-Keycloak pattern fragments the admin allow-list across many places.

## What we already have on GIP

GCP project: `tesseracthub-480811`. Firebase Auth is enabled.

Three tenants live today (visible in mark8ly-auth-bff env vars):

| Tenant | ID | Purpose |
|--------|-----|---------|
| Internal | `MP-Internal-e986p` | Admin/staff users — back-office, sre dashboards, mark8ly admin, devai dashboard |
| Customer | `MP-Customer-39opy` | End-customer users — currently only mark8ly storefront, will absorb fanzone + homechef customers |
| Platform | `Platform-9bu14` | Cross-app platform identities (service accounts, integration tokens) |

GCP Secret Manager already has:
- `prod-firebase-sa-key` — service-account JSON for the Firebase Admin SDK
- `prod-gip-web-api-key`, `prod-mark8ly-gip-web-api-key`, `prod-social-gip-tenant-id` — per-product browser API keys

## Admin allow-list

Only these three accounts get the `admin: true` custom claim on the **Internal** tenant. Every other authenticated user is treated as a customer.

```
samyak.rout@gmail.com
unidevidp@gmail.com
mahesh.sangawar@gmail.com
```

The list is held in `prod-platform-admin-emails` (GCP Secret Manager) and synced into the cluster as a Kubernetes Secret via ExternalSecrets, so adding/removing an admin is a one-secret rotate.

A Kubernetes CronJob (`gip-admin-claims-sync`) runs every 6 hours and on-demand: it reads the allow-list, looks up each user in the Internal tenant, creates them if absent, sets `{"admin": true}`, and **revokes the claim from anyone in the tenant who isn't on the list**. Custom claims propagate to the next ID-token refresh (≤ 1 hour for an active session).

## Migration phases

### Phase 0 — Today

1. ✅ Inventory existing GIP setup (already done).
2. Stand up the admin-claims CronJob (this commit). Verify the 3 emails carry `admin: true`.
3. Decide whether to fix or accept the customer Keycloak outage (probably accept — replacement starts immediately).

### Phase 1 — Build the shared GIP auth-bff

Two paths:

- **(preferred)** Generalise mark8ly-auth-bff into a deployable that products configure with env vars. Pull out the mark8ly-specific OpenFGA + marketplace-api hooks behind feature flags. Each product runs its own instance pointing at the right tenant.
- (fallback) Add GIP support to the existing `ghcr.io/tesseract-nexus/global-services/auth-bff` (Node) image. The current code only speaks Keycloak; this would be a substantial refactor.

The preferred path reuses 90% of the proven Go BFF that already runs in production for mark8ly.

### Phase 2 — Cut over per product

Per product (fanzone, homechef, gameverse later):

1. Deploy `<product>-auth-bff-gip` alongside the existing Keycloak BFF.
2. Update the frontend to use Firebase JS SDK for the login flow. Users hit `/login` → Firebase popup/redirect → BFF exchanges the ID token for an HttpOnly session cookie (same cookie shape as today).
3. Run side-by-side for 24h. Watch error rates, session-set rates.
4. Flip DNS / Istio routes from old BFF to new.
5. Delete the Keycloak BFF + the realm.

### Phase 3 — User migration

For products where users actually exist in Keycloak today, batch-export and import into GIP Customer tenant:

```
keycloak admin → /admin/realms/{realm}/users export → JSON
→ transform to Firebase auth import schema
→ firebase auth:import (Firebase CLI)
```

For most products the user volume is small (test traffic), so a cleaner approach is "log in fresh once" — old Keycloak users sign in via Google to GIP on first visit after cutover and a new GIP user is created.

### Phase 4 — Decommission customer + internal Keycloak

- Drop the `identity-customer` namespace + its CNPG cluster.
- Drop the `identity-internal` namespace + the realm-import jobs.
- Remove `keycloak-google-sso`, `keycloak-postgres-*`, and realm-bootstrap External Secrets.

## What changes on the application side

| Layer | Today (Keycloak) | After (GIP) |
|-------|-------------------|-------------|
| Frontend login | `<a href="https://identity.fanzonebattleground.com/realms/fanzone/protocol/openid-connect/auth?...">` | Firebase JS SDK: `signInWithPopup(googleProvider)` |
| Frontend token | Backed by Keycloak access token + refresh token | Firebase ID token (auto-refresh by SDK) |
| BFF on receive | Exchange Keycloak code → tokens → session cookie | Verify Firebase ID token → session cookie |
| Backend services | Trust `Authorization: Bearer <keycloak JWT>` validated by Keycloak public key | Trust `Authorization: Bearer <firebase ID token>` validated by Firebase Admin SDK |
| Admin check | Role in Keycloak realm role mapper | `admin: true` custom claim — set only on the 3 emails |
| User ID format | UUID minted by Keycloak | Firebase UID (alphanumeric, NOT UUID) |

The UID-format change is the biggest application-level impact. mark8ly already accepts string UIDs (per its docs — *"GIP user IDs are alphanumeric strings, NOT UUIDs"*). Other Go services that expect `uuid.UUID` for user IDs need to widen their column types from `uuid` to `text`.

## Out of scope for this migration

- Service-to-service auth (already uses internal-auth shared secrets, not Keycloak).
- mTLS / Istio AuthorizationPolicy identities.
- The Otto chat's `otto_session` cookie (separate signing key, separate concern).
