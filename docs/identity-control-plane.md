# Identity control plane — self-serve product and tenant onboarding

[`zitadel-onboarding.md`](zitadel-onboarding.md) is a runbook: a human reads it
and makes twelve API calls in order. This file is the design for replacing that
human. It covers what Zitadel's objects actually are, where Zitadel stops and
OpenFGA starts, which objects belong in git and which cannot, and how each half
gets automated.

Read [`zitadel.md`](zitadel.md) first for the deployment, the TESSERIX/ZITADEL
org split, and what `zitadel-bootstrap` already reconciles.

This file assumes every user is authenticated before they touch anything. For
products with an anonymous tier — a guest opens a room, no account, data gone
shortly after — see [`tenancy-model.md`](tenancy-model.md), which covers
capability-based authorization, data TTL, and per-tenant secrets.

The worked example throughout is **HMS**, where a **hospital is a tenant**: one
Zitadel organization per hospital, one Zitadel project for the product, and
OpenFGA for every role and permission inside it.

---

## 1. The object model, and where each object belongs

Five nouns. Getting these straight is most of the work, because Zitadel's
terminology overlaps with words this estate already uses for other things.

| Zitadel object | What it is | In our estate |
|---|---|---|
| **Instance** | The whole deployment behind one hostname. Owns default policies, SMTP, the IAM role set. | Exactly one, `auth.tesserix.app`. Never more. |
| **Organization** | A container of *users*, *domains*, *IdP connections* and *policies*. The unit of isolation. | **One per customer tenant** — one per hospital for HMS — plus TESSERIX for our own staff and every product project. |
| **Project** | A container of *applications* and *roles*. The unit of a product. | **One per product**: `hms`, `homechef`, `mark8ly`. All of them in TESSERIX. |
| **Application** | One OIDC/SAML client inside a project. Holds client id, secret, redirect URIs, grant types. | One per deployable: web, mobile, API. |
| **Grant** | Gives an organization access to a project. | The join between a hospital and the product they bought. |

### The one thing to internalise

**Organizations and projects are orthogonal. They are the two axes of a
multi-tenant SaaS.**

```
                      PROJECTS  (products — one per product, forever)
                 ┌──────────────┬──────────────────┬──────────────────┐
                 │  hms         │  homechef        │  mark8ly         │
   ┌─────────────┼──────────────┼──────────────────┼──────────────────┤
 O │ org: apollo │  ✔ granted   │        —         │        —         │
 R │ (hospital)  │              │                  │                  │
 G ├─────────────┼──────────────┼──────────────────┼──────────────────┤
 S │ org: fortis │  ✔ granted   │        —         │        —         │
   │ (hospital)  │              │                  │                  │
(t ├─────────────┼──────────────┼──────────────────┼──────────────────┤
 e │ org: globex │      —       │    ✔ granted     │    ✔ granted     │
 n │ (other SaaS │              │                  │                  │
 a │  customer)  │              │                  │                  │
 n ├─────────────┼──────────────┼──────────────────┼──────────────────┤
 t │ org:        │  ✔ support   │    ✔ support     │    ✔ support     │
 s)│ TESSERIX    │  ← and every product PROJECT is defined here        │
   │ (us, staff) │              │                  │                  │
   └─────────────┴──────────────┴──────────────────┴──────────────────┘
```

A user lives in **exactly one** organization. A product is **one** project no
matter how many tenants use it. `dr.rao@apollo.com` signing in to HMS gets a
token whose `urn:zitadel:iam:org:id` is Apollo's org id. The same HMS
deployment, the same client id, a different hospital — no per-tenant deploy, no
per-tenant client, no per-tenant secret.

The mistake to avoid is **a project per hospital**. It looks reasonable for the
first three and then every new hospital needs a new client id, hence a new
secret, hence a deploy. That is Keycloak's realm-per-tenant shape rebuilt on the
system chosen specifically to avoid it.

### Why the organization is the isolation unit

Because these four things are org-scoped, and they are exactly what a hospital's
IT department wants to control:

- **Users** — Apollo's staff directory is not Fortis's.
- **Verified domains** — `@apollo.com` maps to Apollo's org, which is what makes
  domain discovery safe (§ 5).
- **IdP connections** — Apollo on Okta, Fortis on Entra, both against one
  hostname. This is the reason Zitadel replaced Keycloak.
- **Policies** — login, password complexity, lockout, MFA. Org policy overrides
  the instance default, so a hospital under its own compliance regime can
  mandate MFA on its own org with no platform change and no ticket.

---

## 2. Zitadel authenticates. OpenFGA authorizes. Do not blur this.

This is the most important boundary in the design, and the one most likely to
rot, because both systems have a thing called a "role".

```
   ┌──────────────────────────────────────────────────────────────────┐
   │  ZITADEL — "who is this, and which hospital are they in?"        │
   │                                                                  │
   │   • authenticates the human (password, or the hospital's IdP)    │
   │   • proves org membership: this person belongs to Apollo         │
   │   • issues a token:  sub, email, org id, tenant_id               │
   └────────────────────────────┬─────────────────────────────────────┘
                                │  token
                                ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  HMS BACKEND — authn.TenantPrincipal(c) → (Principal, tenantID)  │
   └────────────────────────────┬─────────────────────────────────────┘
                                │  check(user, permission, object)
                                ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  OPENFGA — "may THIS person do THIS to THIS object?"             │
   │                                                                  │
   │   • doctor / nurse / ward clerk / billing admin                  │
   │   • department and ward membership                               │
   │   • per-patient, per-record, per-episode access                  │
   └────────────────────────────┬─────────────────────────────────────┘
                                │  tenant id
                                ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  POSTGRES RLS — forced row-level isolation, the last line        │
   └──────────────────────────────────────────────────────────────────┘
```

**Consequence: HMS's Zitadel project defines almost no roles.** Zitadel's
project-role mechanism (`urn:zitadel:iam:org:project:roles` in the token) is
real and works, but for HMS it is redundant with OpenFGA and actively harmful in
parallel — staff roles would live in two systems, drift, and produce "the token
says doctor but FGA disagrees" incidents nobody can debug.

Use Zitadel project roles only for what OpenFGA cannot know at authentication
time, which for HMS is essentially one thing:

| Role | Why it must be in the token |
|---|---|
| `hms-user` | Marks "this org bought HMS". Lets sign-in be refused at the IdP for orgs with no grant, before any HMS code runs. |
| `platform-support` | Granted only to TESSERIX. Distinguishes our staff from hospital staff at the edge. |

Everything else — doctor, nurse, ward, department, "may Dr Rao open this
chart" — is an OpenFGA tuple. HMS already has this shape: a `tenant` type with
`owner`/`admin`/`staff`/`viewer`, `authz.Grant` declared per module, and
authorization that fails closed (FGA errors are 503, never fail open). The
reference model is `charts/apps/mark8ly-fga-init/templates/configmap-model.yaml`;
HMS gets its own `hms-fga-init` chart on the same pattern.

**Rule of thumb: if the answer depends on a row in your database, it is
OpenFGA's, not Zitadel's.** Role explosion in the IdP is how these systems
become unmaintainable.

### The third layer: Zitadel IAM roles

Separate again, and easy to miss: `IAM_OWNER`, `ORG_OWNER`, `PROJECT_OWNER`
govern who may administer *Zitadel itself*. Granting `ORG_OWNER` to a hospital's
first admin lets them manage their own users and IdP connections in the Zitadel
console with no engineering from us at all. That is the cheapest possible
self-service and should be the day-one answer, before any custom UI exists.

### The join keys

Three ids for the same hospital, in three systems. Every one of them must be
stored, once, at creation time.

| System | Identifier | Where it is stored |
|---|---|---|
| Zitadel | `orgId` | `hms.tenants.zitadel_org_id` |
| HMS | `tenants.id` (UUID) | Zitadel org **metadata**, key `tenant_id` |
| OpenFGA | `tenant:<HMS UUID>` | derived from the HMS UUID, never a fourth id |

Storing the HMS UUID *back into Zitadel org metadata* is what makes the next
section work.

### Keeping `tenant_id` in the token

HMS's `backend/pkg/authn` already reads a `tenant_id` claim and returns
`ErrNoTenantClaim` without it — `TenantPrincipal` is the contract every handler
uses. Zitadel does not emit that claim natively; it emits
`urn:zitadel:iam:org:id`.

Two ways to bridge, and the second is better:

**(a) HMS maps org id → tenant UUID** on every request from its own database.
Correct, but it puts a lookup in the authentication path and the principal stops
being derivable from the token alone.

**(b) A Zitadel Action v2 copies the org's `tenant_id` metadata into the token.**
`identity-service` writes that metadata when it creates the org (§ 5), so the
value is already there. HMS's existing claim reader then works unchanged against
Zitadel, and the token stays self-describing.

Actions are runtime objects created through the API, not declarable in a Helm
chart. **Script it and commit the script** — an Action that exists only in the
console is one console mistake away from gone, with no diff to review and
nothing to restore from.

---

## 3. The split that determines the architecture

Onboarding has two halves with opposite requirements, and one piece of software
cannot serve both.

| | Product onboarding | Tenant onboarding |
|---|---|---|
| Who triggers it | Our engineers, once per product | A hospital, at signup, unattended |
| How often | ~10 times a year | Continuously, at any hour |
| Acceptable latency | A PR review | Seconds |
| Should it be in git? | **Yes** — it is infrastructure | **No** — it is customer data |
| Needs cluster changes | Yes (gateway, ESO, DNS) | No |

Putting hospital creation in git means a customer's signup blocks on a PR merge.
Putting product client ids outside git means the estate's auth topology exists
only in a database, with no diff and no review.

So: **two components, one of which already exists.**

```
   tesserix-k8s (git)                      HMS admin UI (runtime)
            │                                        │
            │ Argo CD sync                           │ HTTPS + bearer
            ▼                                        ▼
   ┌────────────────────┐                   ┌─────────────────────┐
   │  zitadel-bootstrap │                   │  identity-service   │
   │  CronJob, */30     │                   │  REST API           │
   │                    │                   │                     │
   │  TODAY: instance   │                   │  orgs, domains,     │
   │   policy, branding,│                   │  IdPs, grants       │
   │   IAM admins       │                   │                     │
   │  ADD: projects,    │                   │  (to be built)      │
   │   apps, secrets    │                   │                     │
   └─────────┬──────────┘                   └──────────┬──────────┘
             │                                         │
             │  iam-admin PAT           iam-admin key  │
             └──────────────────┬──────────────────────┘
                                ▼
                    ┌───────────────────────┐
                    │  auth.tesserix.app    │
                    │  Zitadel Management   │
                    │  API                  │
                    └───────────────────────┘
```

The `iam-admin` credential is effectively root on the identity plane. Only these
two workloads ever hold it.

---

## 4. Product onboarding — extend `zitadel-bootstrap`, do not build an operator

The instinct here is a Kubernetes operator with `ZitadelProject` and
`ZitadelApplication` CRDs. **Don't.** `charts/apps/zitadel-bootstrap` already
does declarative reconciliation of Zitadel from git: a `desired` block in
`values.yaml`, serialised to `/config/desired.json`, diffed field by field
against live and reconciled every 30 minutes, authenticating with the
`iam-admin` PAT. It has unit tests (`files/bootstrap_test.py`) and it already
leaves console-set fields it does not manage alone.

A CRD operator would duplicate all of that to gain a `kubectl get` surface. Add
projects and applications to the thing that exists:

```yaml
# charts/apps/zitadel-bootstrap/values.yaml
desired:
  # Every product project lives in TESSERIX. bootstrap.py already fails its run
  # if a project turns up in the reserved ZITADEL org.
  projects:
    - name: hms
      # Deliberately minimal — staff roles are OpenFGA's, not Zitadel's (§ 2).
      roles:
        - key: hms-user
          displayName: HMS subscriber
        - key: platform-support
          displayName: Tesserix support
      assertRoles: true          # or the roles claim is silently absent
      apps:
        - name: hms-web
          type: WEB              # WEB | USER_AGENT | NATIVE | API
          authMethod: BASIC      # NONE for public clients — PKCE instead
          redirectUris:
            - https://hms.tesserix.app/api/auth/callback
          postLogoutRedirectUris:
            - https://hms.tesserix.app
          # Written once, on creation. Never into a K8s Secret directly.
          secretRef: prod-hms-oidc-client-secret
```

### What the reconciler must get right

1. **Idempotency is by id, not by name.** Search for the project, and once found
   record its id; names are mutable and a rename must not mint a second project.
   The existing `_search` calls in `bootstrap.py` are the pattern.
2. **Send `x-zitadel-orgid` for the TESSERIX org on every project call.** Omit it
   and the project lands in the PAT's own org, which is ZITADEL — and getting one
   out again means a new clientId, a new secret and a cutover
   (`scripts/identity/migrate-zitadel-project.py` exists because this happened).
3. **Role removal is destructive** — it revokes access for everyone holding it.
   Add without asking; remove only behind an explicit `pruneRoles: true`.
4. **Redirect URIs are matched literally.** A trailing-slash mismatch is a
   sign-in failure with no useful error. Normalise before writing.
5. **The client secret is one-time.** On application creation only, write it to
   GCP Secret Manager under `secretRef` and never log it, never keep it. External
   Secrets carries it into the namespace, which is how every other credential in
   this estate travels. The CronJob's ServiceAccount needs a Workload Identity
   binding with `secretmanager.secretVersionAdder` for this — it has none today.
6. **Never regenerate implicitly.** Regeneration is an explicit bump
   (`secretGeneration: 2`). The Zitadel chart already lost live sessions once to
   a credential regenerated on every sync — see the login keypair note in
   `zitadel.md`.

### The part no reconciler can do, and the fix

Steps 3 and 4 of `zitadel-onboarding.md` edit
`charts/infrastructure/istio-auth-policies/values.yaml` — the issuer in
`extraGip`, the hostname in `frontendApps`. That is cluster-wide shared config
owned by Argo CD. A job writing it would fight self-heal, and nothing may be
applied outside git.

Two ways out, and the second is better:

**(a) Open a PR** against `tesserix-k8s` with the values edit. Honest and
reviewable, but product onboarding is still gated on a human.

**(b) Make the gateway rule generic once, so no per-product edit exists.** There
is a single issuer for the whole estate. Register it in `extraGip` **once**, with
no `audiences` and no `restrictToHosts`, so the gateway's only job is *this token
is authentically ours*. Each product then enforces its own audience in its own
namespace:

```yaml
# charts/apps/hms/templates/authorization-policy.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
spec:
  action: ALLOW
  rules:
    - when:
        - key: request.auth.claims[aud]
          values: ["<hms projectId>"]
```

This preserves the isolation `restrictToHosts` was protecting — a HomeChef token
fails HMS's audience check — while moving per-product config into the
per-product chart, where the product team already has write access. Nothing
shared changes when a product is added.

`frontendApps` still needs the hostname, but `*.tesserix.app` is already
wildcarded there for tenant subdomains, so a product on the standard domain
needs no edit at all. Only a custom domain does.

**Verify (b) on a scratch host before adopting it.** Istio merges `jwtRules`
across every `RequestAuthentication` selecting the same workload, and the
`allow-authenticated-api` interaction described in `zitadel-onboarding.md`
Step 3 is exactly what changes when `audiences` is dropped. Under ambient mesh,
confirm the policy is enforced by a waypoint and not by ztunnel, which cannot
evaluate HTTP attributes and drops those rules silently
(`reason: UnsupportedValue`).

---

## 5. `identity-service` — hospitals, at runtime

> Built as **`onboarding-service`** behind `onboard.tesserix.app`. The API
> surface, authorization model, audit ledger and every onboarding scenario are
> specified in [`onboarding-api.md`](onboarding-api.md); this section stays as
> the rationale.

A Go service in the `zitadel` namespace holding the `iam-admin` credential and
exposing a small REST API that **every product calls** instead of each product
learning the Zitadel management API. This is the "global API" the design is for.

Why a service and not a shared library: a library puts the identity-plane root
key in every product's pod. A service puts it in one pod, behind an
authenticated API, with an audit log of who asked for what.

### The hospital onboarding flow

```
 Apollo signs up in HMS
        │
        │  1. POST /v1/tenants  { name: "Apollo", productKey: "hms" }
        ▼
 ┌──────────────────┐         ┌───────────────────────────────────────┐
 │ identity-service ├────────►│ Zitadel                               │
 └──────────────────┘         │  • create org "Apollo"      → orgId   │
        │                     │  • set org metadata tenant_id=<uuid>  │
        │                     │  • grant project `hms`, role hms-user │
        │                     │  • create first human user            │
        │                     │  • make them ORG_OWNER                │
        │                     └───────────────────────────────────────┘
        │  returns orgId
        ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ HMS, in the SAME transaction as its own tenant row:              │
 │   INSERT tenants (id, name, zitadel_org_id)                      │
 │   OpenFGA: write tuple  user:<admin> owner  tenant:<uuid>        │
 └──────────────────────────────────────────────────────────────────┘
        │
        │  2. Apollo's admin verifies their domain
        ▼
   POST /v1/tenants/{orgId}/domains          apollo.com
   POST /v1/tenants/{orgId}/domains/apollo.com/challenge
        └──► returns a DNS TXT record → Apollo's IT publishes it
   POST /v1/tenants/{orgId}/domains/apollo.com/verify   (poll; first try fails)
        │
        │  3. Apollo connects their own SSO
        ▼
   POST /v1/tenants/{orgId}/idps  { type: "okta", issuer, clientId, secret }
        └──► identity-service creates the IdP  AND  binds it to Apollo's
             login policy — in ONE call (see below)
        │
        │  4. Done. From now on:
        ▼
   dr.rao@apollo.com → auth.tesserix.app → domain discovery matches
   apollo.com → Apollo's org → Apollo's Okta → back with a token carrying
   org id + tenant_id → HMS → OpenFGA decides what Dr Rao may do.
```

Steps 2–4 are **the hospital's own work**, in HMS's admin UI. No ticket, no
deploy, no platform engineer.

### Staff sign-in, once onboarded

```
 dr.rao@apollo.com  ──►  hms.tesserix.app  ──►  auth.tesserix.app
                                                      │
                            domain discovery: apollo.com → org: apollo
                                                      │
                                                      ▼
                                              Apollo's Okta  (their MFA,
                                                      │       their policy)
                                                      ▼
        token { sub, email, org id: apollo, tenant_id: <hms uuid> }
                                                      │
                                                      ▼
                       HMS  ──►  OpenFGA: can dr.rao view patient:123?
                                                      │
                                                      ▼
                            Postgres, RLS-scoped to tenant <hms uuid>
```

Domain discovery is already enabled instance-wide
(`loginPolicy.allowDomainDiscovery: true` in `zitadel-bootstrap`), and
self-registration is already off, so a hospital cannot appear except through
this path.

Where HMS already knows the hospital from the subdomain
(`apollo.hms.tesserix.app`), pass `urn:zitadel:iam:org:id:{orgId}` in the scope
instead of relying on discovery. The user never sees a generic login page.

### The API

```
POST   /v1/tenants                                  create org + owner + grant
GET    /v1/tenants/{orgId}
POST   /v1/tenants/{orgId}/domains
POST   /v1/tenants/{orgId}/domains/{d}/challenge    → DNS TXT to publish
POST   /v1/tenants/{orgId}/domains/{d}/verify       → poll; safe to call often
GET    /v1/tenants/{orgId}/idps
POST   /v1/tenants/{orgId}/idps                     okta|entra|google|github|oidc|saml|ldap
DELETE /v1/tenants/{orgId}/idps/{idpId}
POST   /v1/tenants/{orgId}/grants                   grant a project to this tenant
POST   /v1/tenants/{orgId}/members                  add a user / ORG_OWNER
```

Callers authenticate with their own Zitadel machine-user token. The service
authorizes each call against **the caller's project**, not merely against "has a
valid token" — HMS must not be able to read or reconfigure Mark8ly's tenants.
This API is the single highest-value target in the estate.

### Three behaviours that make it genuinely self-serve

**`POST /idps` creates *and* binds, in one call.** Creating an IdP does not make
it usable; it must also be added to the org's login policy
(`POST /management/v1/policies/login/idps`). This is the most common onboarding
failure — the IdP exists, the hospital swears it is configured, the login screen
never offers it. The API must never expose the unbound state.

**Domain verification is a resource, not a boolean.** DNS propagates slowly, so
the first `verify` almost always fails. Return the challenge record, the current
state, and when it was last checked, so HMS can render "waiting for DNS —
checked 30s ago" with a *Check now* button. A hospital told only "failed" opens
a ticket.

**`autoRegister` is a deliberate choice, surfaced to the hospital.** On, anyone
who authenticates at Apollo's Okta is provisioned into Apollo's org on first
sign-in — usually what they want, and also how an over-broad IdP silently fills
an org with people who should not be in it. For a hospital, default it **off**
and let them turn it on.

### Per-IdP notes that come up on every hospital

| Hospital has | Endpoint | Reality |
|---|---|---|
| Entra ID | `/management/v1/idps/azure` | **Not** `/idps/oidc` — tenant-ID routing and non-standard claims mean group and email arrive in the wrong shape otherwise. |
| Okta / generic OIDC | `/management/v1/idps/oidc` | Straightforward. Most common. |
| Google Workspace | `/management/v1/idps/google` | Straightforward. |
| SAML 2.0 | `/management/v1/idps/saml` | Their IdP team needs your SP metadata (ACS URL, entity id), which is derived from the IdP object — so create it first and read the values back. Expect change windows measured in days; show the connection as *pending* so they can see whose turn it is. |
| On-prem AD / LDAP | `/management/v1/idps/ldap` | Needs network reachability from Zitadel's pods into the hospital network. That is a firewall and egress conversation. **Treat LDAP as assisted onboarding, not self-serve.** |

### Tenant secrets are not platform secrets

Apollo's Okta client secret belongs in **OpenBao**, never GCP Secret Manager —
see the secret-store rule in the repo `CLAUDE.md`. It is scoped to one customer,
and Secret Manager is a flat project-wide namespace with no per-tenant boundary.
In practice Zitadel stores the IdP secret in its own encrypted eventstore, so
`identity-service` should pass it straight through and keep no copy at all;
where a copy is genuinely needed, `kv/tenants/{orgId}/idp/{idpId}`.

---

## 6. What the HMS team does, once

1. Add the `hms` project and its applications to `zitadel-bootstrap`'s `desired`
   block. Merge; the CronJob creates them within 30 minutes and writes the client
   secret to `prod-hms-oidc-client-secret`.
2. Add an `ExternalSecret` in `external-secrets/prod/hms/` pulling that secret.
3. Add the audience `AuthorizationPolicy` from § 4(b) to the chart.
4. Add an `hms-fga-init` chart on the `mark8ly-fga-init` pattern — a ConfigMap
   holding the authorization model and a Job that writes it. Keep it in lockstep
   with the model in the HMS repo; that chart's header comment says exactly this
   because the two drifting is a failure that has already happened once.
5. Wire the app against
   `https://auth.tesserix.app/.well-known/openid-configuration`, with the scope
   `urn:zitadel:iam:org:project:id:{projectId}:aud`. Without it, the token HMS's
   own frontend obtains is **not valid for HMS's own backend**.
6. Script and commit the Action v2 that projects org metadata `tenant_id` into
   the token (§ 2), so `authn.TenantPrincipal` keeps working unchanged.
7. Store `zitadel_org_id` on the HMS tenant row. It is the join key, and there is
   no cheap way to look an org up later by your own tenant name.

Everything after that is per-hospital and unattended.

---

## 7. Build order

The value is front-loaded; do not start with the reconciler work.

1. **`identity-service`, tenant endpoints only** — create org, set metadata,
   grant project, add `ORG_OWNER`. This alone unblocks the first hospital. Their
   admin uses the Zitadel console for IdPs: costs nothing, works today.
2. **Domain + IdP endpoints**, so HMS can build its own SSO screen and stop
   sending hospital IT to a Zitadel-branded console.
3. **Projects and apps in `zitadel-bootstrap`**, once enough products exist that
   hand-created projects have drifted. Adopt the live ids rather than recreating.
4. **The § 4(b) gateway change**, verified on a scratch host first.

Everything before step 3 is scripted API calls — a large improvement on a
runbook, for a small fraction of the work.

## Failure modes

Inherited from `zitadel-onboarding.md`, plus the ones specific to this design.

| What you see | Cause |
|---|---|
| `ErrNoTenantClaim` from `authn` | The Action projecting org metadata into `tenant_id` is missing or was deleted in the console (§ 2) |
| Token verifies but carries no roles | Project does not assert roles, or the app is not set to include them — both are required |
| IdP configured but never offered at login | Not bound to the org's login policy — `POST /idps` must do both |
| A hospital sees another hospital's data | Check the RLS scope first; then confirm `tenant_id` came from the token, not from a request parameter |
| `zitadel-bootstrap` fails with "reserved org holds non-platform projects" | A project was created without `x-zitadel-orgid` for TESSERIX (§ 4) |
| `401 Jwt issuer is not configured` | Issuer not in `extraGip` |
| `403 RBAC: access denied` with healthy pods | Hostname not in `frontendApps` |
| 403 with a token that works elsewhere | Missing project-audience scope |
| Management API 403 with a good token | Missing `...:project:id:zitadel:aud` scope on the `iam-admin` token |
| Operating on the wrong hospital | `x-zitadel-orgid` omitted — every `/management/v1/...` call is org-scoped by it |
