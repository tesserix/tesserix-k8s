# Keycloak Decommission → GIP Cutover Plan

Retire `identity-customer` and `identity-internal` Keycloak, move the last three
consumers onto Google Identity Platform, and delete the namespaces.

Supersedes phases 1–2 of [`gip-migration-plan.md`](gip-migration-plan.md) — the
shared GIP auth-BFF it proposed is built and in production. This doc covers what
is actually left.

## State as of 2026-08-15

The auth-BFF layer is **already fully on GIP**. All four BFFs run with
`GIP_PROJECT_ID=tesseracthub-480811` and carry no Keycloak env vars:

| BFF | Namespace | Tenants |
|---|---|---|
| `mark8ly-auth-bff` | mark8ly | `MP-Internal-e986p`, `MP-Customer-39opy`, `Platform-9bu14` |
| `tesserix-auth-bff` | tesserix | same three |
| `homechef-auth-bff` | homechef | project-level, no tenant pin |
| `devai-auth-bff` | devai | `DEVAI_BFF_ALM_TENANT_ID`, `DEVAI_BFF_SRE_TENANT_ID` |

Keycloak itself is still live — 2 replicas in each of `identity-customer` and
`identity-internal`, each with a Redis master and an Istio waypoint.

## Impacted apps

### Still talking to Keycloak — must be cut over (3)

| App | Namespace | Current Keycloak config | Target GIP tenant | Class |
|---|---|---|---|---|
| `devai-api` | `devai` | `DEVAI_AUTH_PROVIDER=keycloak`, realm `tesserix-internal`, url `https://internal-identity.tesserix.app`, client `devai-dashboard` | `DevAI-1mh9c` | admin |
| `stockpilot-web` | `stockpilot` | NextAuth Keycloak provider, realm `stockpilot`, public `https://identity-stock.tesserix.app`, internal `keycloak.identity-internal.svc:8080`, client `stockpilot-web` | `StockPilot-37yur` | admin |
| `tesserix-blog` | `tesserix` | realm `blog`, issuer `https://identity-blog.tesserix.app/realms/blog`, internal `keycloak.identity-customer.svc:8080/realms/blog`, client `blog-bff` | `Blog-znj8b` | customer |

`devai-api` is the cheapest of the three — it already sits behind `devai-auth-bff`,
which is on GIP, so the change is `DEVAI_AUTH_PROVIDER=gip` plus dropping the four
`DEVAI_KEYCLOAK_*` vars. `stockpilot-web` and `tesserix-blog` need real frontend
work: NextAuth/next-auth Keycloak provider → Firebase ID token verification.

`tesserix-blog` also gates on `ALLOWED_AUTHORS` (3 emails) — that allow-list moves
to the `admin: true` custom claim path already run by `gip-admin-claims`.

### Realms with no live workload — delete, no cutover (3)

| Realm | Why dead |
|---|---|
| `fanzone` | namespace `fanzone` does not exist |
| `gameverse` | namespace `gameverse` exists but has zero deployments |
| `homechef` (Keycloak realm) | `homechef-auth-bff` already on GIP; realm is vestigial |

`charts/apps/fanzone-auth-bff` still carries hybrid GIP + `KEYCLOAK_CLIENT_SECRET`
values in git but is not deployed — delete the chart rather than migrate it.

### Realm → tenant map (canonical, from `scripts/identity/keycloak-to-gip-migrate.py`)

```
blog               -> Blog-znj8b        customer
fanzone            -> Fanzone-ut25f     customer
gameverse          -> Gameverse-ftf7f   customer
homechef           -> HomeChef-gufzu    customer
devai + devai-sre  -> DevAI-1mh9c       admin
stockpilot         -> StockPilot-37yur  admin
social-scrapper    -> Social-tuhg7      admin   (pre-existing)
tesserix-internal  -> Platform-9bu14    admin   (pre-existing)
```

## Infrastructure to unwire

**VirtualServices routing to the `keycloak` service (7):**

| Namespace | Name | Host |
|---|---|---|
| `homechef` | `homechef-identity` | `identity.fe3dr.com` |
| `identity-customer` | `identity-fe3dr-vs` | `identity.fe3dr.com` (duplicate of above) |
| `identity-customer` | `customer-idp-vs` | `customer-idp.mark8ly.com` |
| `identity-customer` | `identity-blog-vs` | `identity-blog.tesserix.app` |
| `identity-internal` | `identity-stock-vs` | `identity-stock.tesserix.app` |
| `identity-internal` | `identity-social-vs` | `identity-social.tesserix.app` |
| `identity-internal` | `internal-identity-fe3dr-vs` | `internal-identity.fe3dr.com` |

**RequestAuthentication in `istio-ingress`** — the GIP issuers already exist
alongside the Keycloak ones, so removal is subtractive:

- remove: `jwt-auth-customer`, `jwt-auth-customer-custom`
  (issuers `https://identity.fanzonebattleground.com/realms/{tesserix-customer,master}`)
- keep: `jwt-auth-gip`, `jwt-auth-gip-custom` (`https://securetoken.google.com/tesseracthub-480811`),
  the `-kora` pair, `jwt-auth-google-oidc`, `jwt-auth-kargo-dex`

Driven by `keycloak.customer.*` / `keycloak.master.*` / `keycloak.internal.*` in
`charts/infrastructure/istio-auth-policies/values*.yaml`.

**ArgoCD apps to delete and deregister from their `kustomization.yaml`:**

```
argocd/prod/infrastructure/     identity-customer.yaml  identity-internal.yaml
argocd/prod/apps/global/        identity-customer-secrets.yaml
argocd/prod/apps/homechef/      identity-bootstrap.yaml
argocd/prod/apps/blog/          identity-bootstrap.yaml
argocd/prod/apps/fanzone/       identity-bootstrap.yaml
argocd/prod/apps/gameverse/     gameverse-identity-bootstrap.yaml
argocd/devtest/infrastructure/  identity-customer.yaml  identity-internal.yaml
argocd/pilot/infrastructure/    keycloak.yaml  keycloak-secrets.yaml
                                keycloak-idp-secrets.yaml  identity-customer.yaml
                                identity-internal.yaml
```

**Charts:** `charts/thirdparty/keycloak`, `charts/thirdparty/identity-customer`,
`charts/thirdparty/identity-internal`, `charts/apps/identity-bootstrap`,
`charts/apps/fanzone-auth-bff`

**Secrets:** `sealedsecret/prod/identity`,
`external-secrets/{prod,devtest}/identity{,-customer,-internal}`

**Scripts** (Keycloak-only, delete with the charts): `keycloak-setup-realms.sh`,
`setup-keycloak-admin-sso.sh`, `configure-google-idp.sh`,
`create-google-idp-secrets.sh`, `seal-google-sso-credentials.sh`,
`setup-google-sso-first-broker-login.sh`. Keep
`scripts/identity/keycloak-to-gip-migrate.py` until phase 2 is done.

**Docs to update or retire:** `IDENTITY_URLS.md` (entirely Keycloak),
`customer-keycloak-social-login.md`, `internal-keycloak-admin-bff-fix.md`,
`admin-login-session-cookie-fix.md`, `social-login-setup-runbook.md`, and the
Keycloak sections of `CLAUDE.md` and `homechef-platform.md`.

## Phases

### Phase 1 — Pre-provision users (no user-visible change)

Run the export + migration script against the three live realms. Users are
Google/Facebook social identities with no local passwords, so this is an
email + IdP-link upsert, not a hash import.

```bash
# discovery export -> /tmp/keycloak-users-export.json
# tenant map       -> /tmp/gip-tenants.json  (create_product_tenants.py)
python3 scripts/identity/keycloak-to-gip-migrate.py
```

Verify per-tenant counts and that `admin: true` lands only on the three
allow-listed emails in admin-class tenants.

### Phase 2 — Cut over the three apps

Order by risk, lowest first. Each is its own PR, deployed and verified before
the next.

1. **`devai-api`** — set `DEVAI_AUTH_PROVIDER=gip`, drop `DEVAI_KEYCLOAK_*`,
   drop the `devai-dashboard` client secret ExternalSecret. Verify login at the
   devai dashboard.
2. **`stockpilot-web`** — replace the NextAuth Keycloak provider with Firebase
   ID-token verification against `StockPilot-37yur`. Needs a `stockpilot` repo
   change plus new `GIP_*` values. Verify login at `stockpilot.tesserix.app`.
3. **`tesserix-blog`** — same shape against `Blog-znj8b`; move `ALLOWED_AUTHORS`
   onto the `admin` custom claim. Verify author login and post publish.

After each, confirm no pod in the namespace holds a `KEYCLOAK_*` env var.

### Phase 3 — Unwire infrastructure

1. Delete the 7 VirtualServices (via their charts, not `kubectl`).
2. Remove `jwt-auth-customer` + `jwt-auth-customer-custom` from
   `istio-auth-policies` values.
3. Delete the 4 `identity-bootstrap` ArgoCD apps and deregister them.
4. Confirm `identity.fe3dr.com`, `internal-identity.fe3dr.com`,
   `identity-blog.tesserix.app`, `identity-stock.tesserix.app`,
   `identity-social.tesserix.app`, `customer-idp.mark8ly.com` return NXDOMAIN or
   a deliberate 410 — and that no app still resolves them.

### Phase 4 — Delete Keycloak

1. **Back up both Keycloak databases first** and copy the dumps off-cluster —
   the realm data is the only record of the old user↔identity mapping.
2. Delete the `identity-customer` and `identity-internal` ArgoCD apps
   (finalizer prunes the workloads).
3. Delete charts, secrets, and scripts listed above.
4. Delete namespaces `identity-customer`, `identity-internal`, `identity`.
   Note the Redis PVCs are `standard-rwo` (**Delete** reclaim, not Retain) — they
   are gone the moment the namespace goes.
5. Remove the `identity` AppProject (`argocd/prod/projects/identity.yaml`) once
   nothing references it — Zitadel currently does, see below.
6. Update the docs listed above.

## Open question — Zitadel

`argocd/prod/apps/.../zitadel` exists in the `identity` AppProject with a
3-instance `zitadel-postgres` CNPG cluster provisioned today. The Zitadel app
itself is `OutOfSync / Missing` — no server pod. This overlaps GIP as a
Keycloak replacement.

Decide before phase 4: if GIP is the target, Zitadel and `zitadel-postgres`
should be torn down in the same sweep and the `identity` AppProject deleted with
them. If Zitadel is still wanted for something GIP does not cover, the `identity`
project stays and only the Keycloak apps leave it.

## Rollback

Phases 1 and 3 are reversible from git. Phase 2 is reversible per-app by
reverting the PR **only while Keycloak is still running** — which is why phase 4
is last and gated on all three apps being verified. Once phase 4 runs, rollback
means restoring the database dumps into a fresh Keycloak, so treat it as
one-way.
