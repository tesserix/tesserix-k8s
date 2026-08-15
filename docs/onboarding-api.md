# `onboarding-service` — the platform onboarding API and console

`https://onboard.tesserix.app` — one API that creates organizations, onboards
products to them, and lets a customer connect their own SSO. A Next.js console
on the same host for the platform team, and the identical REST surface for
products to call.

This is the concrete build of the `identity-service` sketched in
[`identity-control-plane.md`](identity-control-plane.md) § 5. That doc explains
*why* org-per-tenant and where the Zitadel/OpenFGA line falls; read it first.
This doc is the *what to build*: API surface, authorization model, storage,
and the failure cases that matter.

| | |
|---|---|
| Repo | `tesserix/onboarding-service` — `apps/api` (Go 1.26 + Gin), `apps/web` (Next.js 16) |
| Chart | `charts/apps/onboarding-service/` |
| Namespace | `onboarding` |
| Host | `onboard.tesserix.app` — `/api/*` → API, everything else → console |
| Database | `onboarding_db` on **`global-postgres`** (no new cluster) |
| Identity | Zitadel `https://auth.tesserix.app`, `iam-admin` machine credential |

---

## 1. What it is, and what it is not

**It is** the only thing in the estate that holds the `iam-admin` credential and
speaks the Zitadel management API. Products never call Zitadel management
directly, and no product pod carries a key that can create an org.

**It is not** the source of truth for identity. Zitadel is. `onboarding_db`
holds a projection and an append-only audit ledger. If the two disagree, Zitadel
wins and the projection is repaired — never the other way round.

**It is not** an authorization service. Who may see a patient record is
OpenFGA's answer, in the product. This service answers only "which organization
exists, which products is it entitled to, and how do its people sign in".

Three consequences that shape everything below:

- Every write is *Zitadel first, then project locally*. A local row is never the
  proof that an org exists.
- Every read that a product depends on for correctness (does this org have a
  grant for my project?) is served from the projection but revalidated against
  Zitadel on a miss, so a stale projection degrades to slow, not to wrong.
- The audit ledger is the product. Losing it is worse than losing the projection,
  which can be rebuilt from Zitadel in a single pass.

---

## 2. The callers, and how each one authenticates

Three classes, and they must not be allowed to blur into "has a valid token".

```
 ┌─────────────────────┐   OIDC code+PKCE, session cookie   ┌──────────────┐
 │ Platform engineer   │──────────────────────────────────► │              │
 │ onboard.tesserix.app│   role platform-admin/operator     │              │
 └─────────────────────┘                                    │              │
                                                            │  onboarding  │
 ┌─────────────────────┐   machine-user JWT, project scope  │   -service   │
 │ Product backend     │──────────────────────────────────► │              │
 │ (HMS, planning-poker│   may touch only ITS OWN project   │              │
 └─────────────────────┘                                    │              │
                                                            │              │
 ┌─────────────────────┐   end-user token + org claim       │              │
 │ Customer org admin  │──────────────────────────────────► │              │
 │ (in a product's UI) │   ORG_OWNER of exactly that org    │              │
 └─────────────────────┘                                    └──────┬───────┘
                                                                   │
                                            iam-admin PAT (one pod) │
                                                                   ▼
                                                            ┌──────────────┐
                                                            │   Zitadel    │
                                                            └──────────────┘
```

| Caller | Credential | Scope of what it may do |
|---|---|---|
| Platform engineer | Zitadel OIDC session cookie (auth code + PKCE), sealed, `SameSite=Lax`, `Secure`, `HttpOnly` | Everything, gated by role: `platform-admin` writes, `platform-operator` reads |
| Product backend | Zitadel machine-user JWT, audience-scoped to the `onboarding` project | Only orgs granted its own project; only its own project's grants |
| Customer org admin | End-user token carrying `urn:zitadel:iam:org:id` | Only the org in that claim, and only domains/IdPs/members — never grants |

**The rule that carries the most weight:** authorization is computed from the
token's *own* claims joined against the projection, never from a path parameter.
`GET /v1/orgs/{orgId}` where `orgId` came off the URL and the caller is a product
token is only served if `org_products` holds a row `(orgId, callersProjectId)`.
HMS holding a valid token is not permission to read Apollo's config unless Apollo
is an HMS customer.

### Why a session cookie for humans and not a bearer token

The console is first-party on the same host as `/api`, so the cookie is
first-party, CORS never enters the picture, and there is no token in
`localStorage` for an XSS to lift. The cost is CSRF, paid with a double-submit
header (`X-CSRF-Token`) required on every non-GET — the same shape as
`secret-service`, which is the working precedent for this exact pairing.

### Machine users, one per product

Each product gets its own Zitadel machine user in the TESSERIX org, with a role
on the `onboarding` project and a `product_key` in its user metadata. The service
resolves the token's `sub` to a row in `products` and everything downstream is
scoped by that row. A product that loses its key has one credential rotated; no
other product is affected, and the audit ledger names which product acted.

There is no shared API key, and no static bearer token in a values file.

---

## 3. Every scenario the API has to cover

### S1 — Platform onboards a brand-new product (project)

The one flow that is *not* self-serve, because it changes the estate.

```
console: New product
   name  "HMS"    key "hms"    hosts hms.tesserix.app
        │
        ▼
POST /v1/products
   ├─ Zitadel: create project "hms" in TESSERIX  (never in ZITADEL)
   ├─ Zitadel: create OIDC app (web, PKCE) + API app (JWT)
   ├─ Zitadel: create machine user  svc-hms  → key
   ├─ GCP SM:  prod-hms-oidc-client-secret, prod-hms-machine-key
   └─ DB:      products row + audit event
        │
        ▼
returns a checklist the console renders as copyable YAML:
   • zitadel-bootstrap `desired.projects` entry  (git, so a rebuild reproduces it)
   • ExternalSecret for external-secrets/prod/hms/
   • the issuer/audience AuthorizationPolicy snippet
```

The API creates the live objects; the YAML it hands back is what makes them
reproducible. Both are needed — see § 6.

### S2 — Platform creates an organization and grants it products

```
POST /v1/orgs            { name: "Apollo Hospitals", ownerEmail: … }
POST /v1/orgs/{id}/grants { productKey: "hms", roles: ["hms-user"] }
```

Used for enterprise deals closed by a human, and as the break-glass path when a
product's own signup is broken.

### S3 — A product self-serves an organization for its customer

Identical API, product machine token instead of a session. This is HMS's signup
form and planning-poker's *Upgrade to Organization* button, and it is the volume
path.

```
HMS backend ──► POST /v1/orgs
                Authorization: Bearer <svc-hms JWT>
                Idempotency-Key: <uuid>
                { name, ownerEmail, productKey: "hms" }
                     │
                     ├─ productKey must equal the caller's own key  (403 if not)
                     ├─ creates org, sets metadata tenant_id=<uuid>,
                     │  grants project hms, makes ownerEmail ORG_OWNER
                     └─ returns { orgId, tenantId }
                     │
HMS, in its own tx: INSERT tenants(id=tenantId, zitadel_org_id=orgId)
                    OpenFGA: user:<owner> owner tenant:<tenantId>
```

The `tenantId` is generated by this service and written to Zitadel org metadata
in the same call, so the claim the product later reads from a token and the row
in the product's database are the same UUID by construction. This is the single
join key; § 2 of `identity-control-plane.md` covers why it must be a claim.

### S4 — An existing organization adds a second product

Apollo already uses HMS and buys planning-poker. `POST /v1/orgs/{id}/grants`
with `productKey: planning-poker`. Their people, their SSO, their domain all
carry over untouched; only the grant is new. This is the payoff of
org-per-tenant, and the reason a product must never be a Zitadel org.

A product token may create a grant **only for its own project**, and only if the
caller can already see the org — i.e. it already has a grant. Cross-selling into
someone else's customer is a platform action, not a product one.

### S5 — Customer verifies a domain

```
POST /v1/orgs/{id}/domains            { domain: "apollo.com" }
POST /v1/orgs/{id}/domains/{d}/challenge  → { type: "TXT", name, value }
POST /v1/orgs/{id}/domains/{d}/verify      → { state: pending|verified, checkedAt }
```

Verification is a resource with a state and a timestamp, not a boolean, because
DNS propagates slowly and the first check nearly always fails. The console and
every product UI render "waiting for DNS — checked 30s ago" with a *Check now*
button. `verify` is safe to call repeatedly and is rate-limited per domain.

### S6 — Customer connects their own SSO

```
POST /v1/orgs/{id}/idps  { type: "okta"|"entra"|"google"|"github"|"oidc"|"saml"|"ldap", … }
```

**Creates the IdP and binds it to the org's login policy in one call.** Never
expose the unbound state; an IdP that exists but is not bound is invisible at the
login screen and is the most common onboarding failure. If the bind fails, the
create is rolled back and the call returns an error — a half-configured IdP is
worse than none.

The client secret is passed straight through to Zitadel and **not stored here**.
Zitadel keeps it in its encrypted eventstore. Where a copy is genuinely needed it
goes to OpenBao at `products/{product}/tenants/{tenantId}/idp/{idpId}` — never
GCP Secret Manager, which is the platform's store (see `CLAUDE.md`, and
[`tenant-secrets.md`](tenant-secrets.md) for the path rules).

`autoRegister` defaults **off** and is surfaced as an explicit choice. On, anyone
who can authenticate at the customer's IdP is provisioned into their org on first
sign-in; that is usually wanted and is also how an over-broad IdP quietly fills an
org with the wrong people.

Per-IdP endpoint quirks (Entra is `/idps/azure`, not `/idps/oidc`; SAML needs SP
metadata read back after create; LDAP needs egress into the customer network and
is assisted, not self-serve) are tabulated in `identity-control-plane.md` § 5.

### S7 — Customer manages their own members

`POST|DELETE /v1/orgs/{id}/members`, restricted to `ORG_OWNER` of that org.
Adding a member here means "may administer this organization in Zitadel". It does
**not** mean "is a doctor at Apollo" — that is an OpenFGA tuple written by HMS.
Keeping those two apart is what stops role vocabulary drifting across two systems.

### S8 — A product asks how a user should sign in

The read path products call on every login page.

```
POST /v1/discovery/resolve   { emailDomain: "apollo.com" }
   → { orgId, orgScope: "urn:zitadel:iam:org:id:<orgId>",
       idps: [ { id, name, type } ] }
```

`POST`, not `GET /orgs?domain=`, so the domain is not in access logs or the
Referer header, and it is rate-limited per product token: this endpoint is an
organization-enumeration oracle if left open. It returns IdP *display* metadata
only — never issuers, client ids, or endpoints.

Where the product already knows the org from the subdomain
(`apollo.hms.tesserix.app`) it should skip discovery and pass `orgScope`
straight into the authorize request. The user never sees a generic login page.

### S9 — Offboarding

| Action | Exposed? |
|---|---|
| Revoke a product grant | Yes — `DELETE /v1/orgs/{id}/grants/{productKey}`, platform or the owning product |
| Remove an IdP | Yes — `DELETE /v1/orgs/{id}/idps/{idpId}`, org admin |
| Deactivate an org | Yes — `POST /v1/orgs/{id}/deactivate`, platform only, reversible |
| **Delete an org** | **No.** Console only, by a human, with the Zitadel audit trail |

Deletion is irreversible and destroys every user in the org. An HTTP endpoint
that can do it is a single compromised product token away from an outage. The
API stops at deactivate, which is reversible and covers every legitimate need.

### S10 — Break-glass

If Zitadel is unreachable, this service is read-only from the projection and
returns `503` on every write. It never falls back to a local decision. The
recovery path is the ZITADEL org's break-glass admin in the console, exactly as
today; this service adds no second root of trust.

---

## 4. API surface

Every mutating call accepts `Idempotency-Key`; every response carries
`X-Request-Id`, which is also the correlation id in the audit ledger.

```
Products (platform only)
  POST   /v1/products                       create project + apps + machine user
  GET    /v1/products
  GET    /v1/products/{key}
  POST   /v1/products/{key}/rotate-secret   rotates client secret, writes GCP SM

Organizations
  POST   /v1/orgs                           create org + owner + optional grant
  GET    /v1/orgs                           scoped: platform=all, product=its own
  GET    /v1/orgs/{id}
  PATCH  /v1/orgs/{id}                      name, branding
  POST   /v1/orgs/{id}/deactivate           platform only
  POST   /v1/orgs/{id}/reactivate           platform only

Grants
  GET    /v1/orgs/{id}/grants
  POST   /v1/orgs/{id}/grants
  DELETE /v1/orgs/{id}/grants/{productKey}

Domains
  GET    /v1/orgs/{id}/domains
  POST   /v1/orgs/{id}/domains
  POST   /v1/orgs/{id}/domains/{domain}/challenge
  POST   /v1/orgs/{id}/domains/{domain}/verify
  DELETE /v1/orgs/{id}/domains/{domain}

Identity providers
  GET    /v1/orgs/{id}/idps
  POST   /v1/orgs/{id}/idps                 creates AND binds
  PATCH  /v1/orgs/{id}/idps/{idpId}
  DELETE /v1/orgs/{id}/idps/{idpId}

Members
  GET    /v1/orgs/{id}/members
  POST   /v1/orgs/{id}/members
  DELETE /v1/orgs/{id}/members/{userId}

Login integration
  POST   /v1/discovery/resolve              email domain → org + idp hints
  GET    /v1/orgs/{id}/login-config         orgScope + idp display metadata

Audit
  GET    /v1/audit                          filter by org, product, actor, action
  GET    /v1/orgs/{id}/audit

Operational
  GET    /healthz    /readyz    /api/auth/me
```

Errors are RFC 7807 problem documents. A caller that is not entitled to an org
gets `404`, not `403`, so the API does not confirm that an org id exists.

---

## 5. Storage — `onboarding_db` on `global-postgres`

No new cluster. `global-postgres` already hosts eleven databases and is a
configured target of `db-schema-bootstrap`; the policy is in
[`postgres-cluster-policy.md`](postgres-cluster-policy.md). A dedicated role
`onboarding` owns the database, so the credential is scoped to it and not to
`global`.

```
products          key, zitadel_project_id, machine_user_id, oidc_client_id,
                  hosts[], state, created_at
organizations     id (= tenant_id UUID), zitadel_org_id, name, primary_domain,
                  state, created_by_product, created_at
org_products      org_id, product_key, roles[], granted_at, revoked_at
                  PRIMARY KEY (org_id, product_key)
domains           org_id, domain, state, challenge_type, challenge_value,
                  last_checked_at, verified_at
idps              org_id, zitadel_idp_id, type, display_name, auto_register,
                  state, created_at            -- no secrets, ever
idempotency_keys  key, actor, request_hash, response_body, status, expires_at
audit_events      id, occurred_at, actor_type, actor_id, product_key, org_id,
                  action, target, outcome, request_id, prev_hash, hash
```

Three properties are enforced in SQL, not in Go, because Go is what gets
compromised:

**`audit_events` is append-only.** The `onboarding` role is granted `INSERT` and
`SELECT` and nothing else on it; `UPDATE` and `DELETE` are revoked. An attacker
with the application's own credential can still write a misleading event but
cannot erase the one that records how they got in.

**The ledger is hash-chained.** Each row stores `prev_hash` and a `hash` over its
own fields plus `prev_hash`. Deleting or editing a row breaks the chain, which a
scheduled verification job detects. Without the chain, append-only is only as
strong as the database's own access control.

**`organizations.id` is the `tenant_id`.** It is generated here, written to
Zitadel org metadata, carried in the token, and stored on the product's own
tenant row. One value in four places, never re-derived from a name.

The projection carries no secret material. The worst case for a full dump of
`onboarding_db` is disclosure of customer names, domains, and which products they
bought — bad, but not a credential compromise. That is the point of keeping IdP
secrets in Zitadel's eventstore.

---

## 6. What still lives in git

The API creates live objects. It cannot be the only record of them, or a cluster
rebuild loses the estate. So `POST /v1/products` returns the YAML it would take
to reproduce what it just made, and the console shows it as a copyable block with
the target path:

| Object | Reproduced by |
|---|---|
| Project, applications, roles | `charts/apps/zitadel-bootstrap/values.yaml` → `desired.projects` |
| Client secret plumbing | `external-secrets/prod/{product}/` |
| Issuer + audience enforcement | the product chart's `AuthorizationPolicy` |
| Database, role, schema | `charts/apps/db-schema-bootstrap/schemas/…` |

Organizations, domains and IdPs are **not** in git and must not be. They are
customer runtime data, they change without a deploy, and there are eventually
thousands of them. `zitadel-bootstrap` reconciles instance policy and the
TESSERIX/ZITADEL org invariants; it must never try to reconcile customer orgs.

---

## 7. Security requirements

Non-negotiable, in rough order of how much damage skipping each one does.

1. **`iam-admin` exists in exactly one pod.** Mounted from GCP Secret Manager via
   ESO into `onboarding-service-api` and nowhere else. No product, no CronJob, no
   console.
2. **Per-caller scoping on every handler**, computed from the token, joined
   against `org_products`. Tested with an explicit "HMS cannot read Mark8ly's
   org" case, not merely by reading the code.
3. **No secret in a response body, ever** — including the one that just created
   it. `POST /v1/products` writes the client secret to GCP Secret Manager and
   returns the secret's *name*. The console shows a link, not a value.
4. **CSRF on every non-GET from a session**, double-submit header. Machine tokens
   are exempt because they are not ambient credentials.
5. **Rate limits** per token and per IP: strict on `/v1/discovery/resolve` and
   `/domains/{d}/verify`, moderate on writes. Discovery is an enumeration oracle
   and verify is a DNS amplification lever.
6. **Idempotency on every write.** A retried `POST /v1/orgs` must return the
   first result, not create a second Apollo. Keys are scoped to the actor so one
   caller cannot replay another's response.
7. **`404` not `403`** for entitlement failures, so ids cannot be probed.
8. **Structured audit before the response is written**, including failures.
   An event whose write fails fails the request; a silent audit gap is worse than
   a 500.
9. **Email allowlist plus role** for console access. The allowlist is the
   backstop for a Zitadel misconfiguration and costs nothing.
10. **Deny-by-default NetworkPolicy**: ingress only from the ingress gateway,
    egress only to Zitadel, `global-postgres`, OpenBao, GCP Secret Manager and
    DNS. It talks to the internet for nothing else.
11. **`readOnlyRootFilesystem`, non-root, dropped capabilities, seccomp
    `RuntimeDefault`** on both workloads.
12. **No org deletion endpoint.** § S9.

---

## 8. Build order

Each step is useful on its own; do not build the console before the API works.

1. **Skeleton + auth**: config, OIDC session, machine-token verification, the
   scoping middleware, audit ledger, `/healthz`. Nothing else is safe to build on
   an unfinished authorization layer.
2. **Organizations + grants** (S2, S3, S4). This unblocks the first real customer.
3. **Domains + IdPs** (S5, S6), which is what makes it self-serve.
4. **Discovery + login-config** (S8), so products can build their own login page.
5. **Products** (S1) — the platform team can create a project in the console by
   hand until there are enough products for that to hurt.
6. **The Next.js console**, once the API it wraps is stable.
7. **Chart, ArgoCD app, ExternalSecrets, NetworkPolicy**, then cut over.

---

## Failure modes

| What you see | Cause |
|---|---|
| Two orgs named Apollo | Retried `POST /v1/orgs` without `Idempotency-Key` |
| IdP configured, never offered at login | Created but not bound to the login policy — `POST /idps` must do both, atomically |
| Product reads an org it does not own | Scoping middleware bypassed on that handler; the `org_products` join is missing |
| `ErrNoTenantClaim` in a product | Org metadata `tenant_id` never set, or the projecting Action was deleted in the console |
| Writes return `503`, reads work | Zitadel unreachable — by design; do not add a local fallback |
| Audit chain verification fails | Rows edited or deleted out of band; treat as an incident, not a bug |
| Management API `403` with a good token | `iam-admin` token missing `…:project:id:zitadel:aud` scope |
| Operating on the wrong org | `x-zitadel-orgid` omitted — every `/management/v1/…` call is org-scoped by it |
| Org exists in Zitadel, absent locally | Projection drift; reproject from Zitadel, never repair Zitadel from the projection |
