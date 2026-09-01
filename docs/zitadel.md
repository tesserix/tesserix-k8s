# Zitadel — identity platform

Zitadel runs at **`https://auth.tesserix.app`** in the `zitadel` namespace. It is
the replacement for Keycloak (`identity-customer`, `identity-internal`), which
stays up until every product has moved.

Why it replaces Keycloak: a tenant's SSO connection binds to **one
organization**, not the whole instance, so a single hostname federates GitHub,
Google, Okta and Entra per tenant without a realm each. Keycloak needs a realm
per tenant, and a realm is a heavyweight object to create, template and keep in
step.

To move a product onto it, or to let a product's tenants connect their own IdP,
see [`zitadel-onboarding.md`](zitadel-onboarding.md). This file covers the
deployment itself.

## What is deployed

| Argo CD Application | Path | Wave |
|---|---|---|
| `zitadel-secrets` | `external-secrets/prod/zitadel` | -1 |
| `zitadel-postgres` | `charts/apps/zitadel-postgres` | 0 |
| `zitadel` | `charts/thirdparty/zitadel` | 1 |

All three sit in the `identity` AppProject. The chart wraps upstream
`zitadel/zitadel` 10.0.4 (app v4.15.3).

The API and console are one HTTP/2 service on 8080; the login UI is a separate
Next.js service on 3000 serving `/ui/v2/login`. The VirtualService splits on
that prefix.

## It has its own ingress gateway, and must

`auth.tesserix.app` is served by `zitadel-ingressgateway`, not the shared
`istio-ingressgateway`. The shared gateway carries `jwt-auth-gip` and three
sibling `RequestAuthentication` policies, all selecting `istio: ingressgateway`
with no host scoping. Istio rejects a bearer token that is present but
validates against no configured issuer — and Zitadel's console access tokens
and PATs are **opaque**, not JWTs. Every authenticated call therefore died at
Envoy with `401 Jwt is not in the form of Header.Payload.Signature` and never
reached the API. The console showed "Your authorization token has expired";
the API logs showed nothing at all, because nothing arrived.

`RequestAuthentication` cannot be scoped by host, so a separate gateway
workload is the only fix. HomeChef hit the same wall — see
`argocd/prod/infrastructure/homechef-ingress-gateway.yaml`.

The VirtualService lists both gateways, so the Cloudflare tunnel route
(`auth.tesserix.app` → `zitadel-ingressgateway.istio-ingress.svc:80`) can be
flipped and reverted without a window where nothing serves. Verify which
gateway is in use by sending a junk bearer token: a `text/plain` body means
the shared gateway is still in front of it.

## The login UI is a fork

Login v2 runs from `tesserix/zitadel`, branch `feat/aurora-theme`, cut from tag
`v4.15.3` — it carries the aurora background and the side-by-side brand panel.
The UI has no standalone repo; it is `apps/login` inside the monorepo.

Release it whenever the theme changes, then bump `login.image.tag`. The image is
built by `tesserix-login-release.yml` in the fork, which fires on any
`v*-aurora.*` tag — never build it by hand:

```bash
git tag v4.15.3-aurora.N && git push origin v4.15.3-aurora.N
gh run watch --repo tesserix/zitadel
```

The workflow generates `@zitadel/proto` and builds `@zitadel/client` first;
neither is produced by `pnpm install` and the Next build cannot resolve them
without both.

`NEXT_PUBLIC_THEME_LAYOUT` and friends live in `apps/login/.env` because Next
inlines them into the client bundle at build time — the entrypoint does no
substitution, so setting them on the pod does nothing. Per-tenant colour, logo
and tagline are read at runtime from the org's label policy and metadata.

The layout is also chosen client-side, after hydration, so the server always
emits the side-by-side markup regardless of viewport. That markup is therefore
responsive on its own (stacked below `md`) — a phone must not have to wait for
hydration to get a usable page.

Login v2 is selected per OIDC application. `zitadel-bootstrap` reconciles each
declared `loginBaseUri` through the Application V2 API while leaving client
secrets and callback URIs untouched. The Registry, MCP, and AgentGateway browser
clients all use `https://auth.tesserix.app/ui/v2/login`; this makes an external
Google login return through `https://auth.tesserix.app/idps/callback`, which is
the callback registered on the shared Google OAuth client. A client that falls
back to legacy `/ui/login/login` instead uses a different Google callback and
fails with `redirect_uri_mismatch`.

## Three things that will bite you

**The masterkey is immutable.** Every encryption key in the eventstore is
derived from `prod-zitadel-masterkey`. It must be exactly 32 bytes, and
changing it makes the existing database unreadable — there is no re-key.

**The service speaks h2c, not HTTP/1.** gRPC and REST share port 8080. The
Service carries `appProtocol: kubernetes.io/h2c` so the gateway does not
downgrade; drop it and the console fails with protocol errors that look like
routing bugs.

**The login client keypair must not be chart-generated.** Upstream guards
regeneration with Helm's `lookup`, which returns nothing under Argo CD's
client-side templating, so every sync would mint a new key and invalidate live
sessions. `login.loginServiceKeySecretName` points at an External Secrets copy
instead.

## Database

`zitadel-postgres` is a three-instance CNPG cluster in the same namespace.
Three, not one, because this is the authentication path for the estate on
Spot-only nodes and losing one still has to leave a replica to promote — see [`postgres-cluster-policy.md`](postgres-cluster-policy.md) for why
that policy has a per-product exception here.

Zitadel's own init Job creates the `zitadel` database, role and grants using
the CNPG-generated superuser (`zitadel-postgres-superuser`). The cluster's
`initdb` therefore creates a throwaway `app` database and nothing else. The
role's password comes from `prod-zitadel-db-password`, not from CNPG, because
CNPG never creates that role.

Backups write to `gs://tesseract-prod-backups-in/zitadel-postgres` at 02:30
daily, keeping the latest three — see
[`gcs-backup-lifecycle/README.md`](gcs-backup-lifecycle/README.md) for why the
bucket rule sits at 10 days rather than 3. They depend on an
`iam.workloadIdentityUser` binding for
`app-secrets-infra-prod@tesseracthub-480811.iam.gserviceaccount.com` on
`zitadel/zitadel-postgres` — CNPG authenticates as the KSA it generates, so
without the binding the WAL archive retries forever and `CNPGWALArchiveFailing`
fires within ten minutes.

A backup that has never been restored is not a backup. Rehearse it against a
throwaway cluster before relying on it — see
[`cnpg-backup-restore.md`](cnpg-backup-restore.md).

### Passwordless connections (mutual TLS)

The `zitadel` role authenticates with a **client certificate**, not a password.
GCP IAM database authentication is a Cloud SQL feature and does not exist for
self-hosted Postgres; certificate auth with the CN mapped to the role is the
equivalent, and CNPG supports it natively.

The chain, all in `charts/apps/zitadel-postgres`:

1. A cert-manager self-signed CA, `zitadel-postgres-client-ca`. CNPG's own CA
   secret cannot be reused — it publishes `ca.crt`/`ca.key` while cert-manager's
   CA issuer reads `tls.crt`/`tls.key`.
2. Client certificates issued from it, with `commonName` set to the Postgres
   role. Postgres maps CN to role, so the two must match exactly.
3. The Cluster sets `certificates.clientCASecret`. Overriding the client CA
   means CNPG can no longer mint the `streaming_replica` certificate itself, so
   `replicationTLSSecret` is supplied as well — **omit it and replicas silently
   never join.**
4. `pg_hba` gets `hostssl all zitadel all cert`. First match wins and a failed
   match is never retried, so the password stops being an authentication path.

Zitadel connects with `Mode: verify-full` — a client certificate is only an
identity if the server presenting itself is verified too. Note that `RootCert`
is the *server* CA (`zitadel-postgres-ca`), not the client CA.

Two deliberate exceptions:

- `ZITADEL_DATABASE_POSTGRES_USER_PASSWORD` is still set. The init Job runs
  `CREATE ROLE ... PASSWORD` before any certificate exists to authenticate with.
  It is no longer usable for login.
- The **superuser stays on password auth**. It is the escape hatch if a
  certificate expires or the CA is rotated badly. Do not add a `cert` rule for
  it without another way in.

## Credentials

Secrets read from GCP Secret Manager:

| GCP Secret Manager | Kubernetes Secret | Used by |
|---|---|---|
| `prod-zitadel-masterkey` | `zitadel-masterkey` | every Zitadel container |
| `prod-zitadel-db-password` | `zitadel-db-credentials` | the `zitadel` DB role |
| `prod-zitadel-admin-password` | `zitadel-admin-password` | first-instance human admin — that account was deleted 2026-08-19; **no user matches this value now** |
| `prod-zitadel-login-service-crt` / `-key` | `zitadel-login-service-key` | login v2 → API |
| `prod-zitadel-resend-api-key` | *(none — read once, held in Zitadel)* | SMTP password, entered through `/admin/v1/smtp` rather than mounted |

Secrets Zitadel writes back on first setup, in the `zitadel` namespace:

- `iam-admin` (key `iam-admin.json`) — machine key for the `iam-admin` service
  user. This is the credential the platform uses to create tenant
  organizations and IdP connections through the API.
- `iam-admin-pat` (key `pat`) — the same user as a personal access token.

Both are created once. Deleting them does not regenerate them; issue a new key
through the console instead.

## Instance configuration

Set in `charts/thirdparty/zitadel/values.yaml` under
`zitadel.zitadel.configmapConfig.DefaultInstance`, and applied only when the
instance is first created. Later changes belong in the console or the API — the
config is not reconciled.

Notable choices:

- `Restrictions.DisallowPublicOrgRegistration: true` — organizations are
  created by the platform on a tenant's behalf, not by anyone who can reach the
  hostname.
- `LoginPolicy.AllowDomainDiscovery: true` — routes a user to their
  organization's IdP by email domain. This is what makes one hostname serve
  every tenant's SSO.
- `Features.LoginV2.Required: false` — applications opt into login v2 with
  their own `loginVersion`; forcing it instance-wide overrides per-app base
  URIs in the deployed Zitadel version.
- `LockoutPolicy` 10 attempts — upstream ships `0`, meaning no lockout at all.
- `PasswordComplexityPolicy.MinLength: 12`.

Per-organization policy overrides everything here, so a tenant can force MFA or
disable password login without touching this file.

## Organizations — every product lives in TESSERIX, ZITADEL is reserved

**Every product project belongs in TESSERIX**, and since the AgentGateway move
none is left outside it.

The *default* org is a separate question and is still `ZITADEL`: an unscoped
login resolves the default org's Google IdP, and promoting TESSERIX before an
instance-level IdP exists breaks federated sign-in with `validation_failed`
(#359). Where projects live and where users land are independent — do not
change one because the other moved.

**The ZITADEL org cannot be deleted or deactivated, and must not be.** It is the
instance's initial org and it owns:

- the `ZITADEL` project — the console, and the Admin, Management and Auth API
  applications. Removing it takes `auth.tesserix.app` down completely.
- `iam-admin`, the service user behind the PAT `zitadel-bootstrap` authenticates
  with. Deactivating the org kills the reconciler along with it.

Verified on the live instance 2026-08-28: the `ZITADEL` project owns four ACTIVE
applications — Management-API, Admin-API, Auth-API and Management Console — and
`iam-admin` (`386261254652101258`) is owned by this org. Both halves of the claim
above hold.

**The break-glass admin is `instance-admin`, and it lives in TESSERIX — not here.**
This list used to name `zitadel-admin` in the ZITADEL org. That account was
Zitadel's generated first-instance admin
(`zitadel-admin@zitadel.auth.tesserix.app`, created 2026-08-14 alongside
`iam-admin`) and it was **deliberately replaced**: the account was created in
TESSERIX on 2026-08-19 05:04 and the original removed five minutes later, both
carrying the same `unidevidp@gmail.com` address. Nothing was lost; the docs
simply were not updated. It was renamed from `admin.user` to `instance-admin` on
2026-08-28.

So the break-glass account today is:

```
instance-admin   386915955290145068   org TESSERIX   IAM_OWNER   password set 2026-08-19
```

Two properties to preserve, because they are what make it break-glass:

- **It keeps a password.** Federated sign-in is not a recovery path — it is one of
  the things that can break. It gained a Google link on 2026-08-28, which
  is fine; the password is what matters and must not be removed.
- **It has a password reset, since 2026-08-28.** Before that there was no SMTP
  provider, so losing the password meant losing admin access outright. Email now
  goes out through Resend — see *What is not in git* below. Note the value in
  `prod-zitadel-admin-password` is still no help: it belonged to the deleted
  first-instance account, not to this one.

Known limitation, accepted deliberately: `instance-admin` sits in TESSERIX, the same
org as everyday logins, so it shares a failure domain with them. An org-level
login-policy break in TESSERIX — the class of bug behind the 0s
`passwordCheckLifetime` loop — would take it down too. Some protection remains in
that `samyak.rout@gmail.com` is IAM_OWNER, password-only and has never linked an
IdP, so a purely IdP-side failure does not lock everyone out. Moving break-glass
into the ZITADEL org would isolate it properly; that was weighed and not done.

So it is emptied of products rather than removed: `zitadel-bootstrap` fails the
run if any project other than `ZITADEL` appears in the ZITADEL org. Nothing is
deleted automatically — a project holds live OIDC clients, and dropping one
takes an application's logins down.

If that check fires, move the project out with the runbook below.

### Moving a project between orgs

There is no API for it. A project's org is fixed at creation, so a move is a
recreate plus a cutover, and the new app gets a **new clientId and a new client
secret**. Existing sessions do not survive it.

```bash
export ZITADEL_PAT=$(kubectl get secret iam-admin-pat -n zitadel -o jsonpath='{.data.pat}' | base64 -d)
scripts/identity/migrate-zitadel-project.py --project <name> --to-org TESSERIX          # dry run
scripts/identity/migrate-zitadel-project.py --project <name> --to-org TESSERIX --apply
```

Then, in order:

1. Store the printed secret: `gcloud secrets versions add <secret> --project=tesseracthub-480811 --data-file=-`
2. Update `clientId` in the app's Helm values, commit, let ArgoCD sync.
3. Restart the pods so ESO re-reads the secret, and verify a real login.
4. Only then delete the old project from the ZITADEL org, in the console.

The script never deletes anything, so until step 4 the old clientId still works
and the cutover rolls back by reverting step 2.

## Branding, login policy and admins are reconciled

`charts/apps/zitadel-bootstrap` runs a CronJob every 30 minutes that reconciles
the instance label policy, the two logo assets, the instance login policy and
the IAM_OWNER list from `values.yaml`. It exists because all of those were
console-only settings that nothing detected drifting.

Every step compares desired to live and writes only on a difference. Fields the
chart does not declare are left alone, so a console change to something outside
`desired` survives. Logos are compared by content hash — an unconditional
re-upload would mint a new asset URL each run and invalidate every cached logo.
The label policy is edited as a preview and only activated when something
actually changed, which is the workflow the assets API requires.

Admins are matched by login name or by **verified** email, because a federated
admin's login name is their IdP subject, not their address. An admin who has
never signed in does not exist yet and is skipped rather than failing the run.

**Machine users, instance memberships and the IAM_OWNER allowlist are reconciled
too, as of this change.** `desired.machineUsers` creates a machine user that
does not yet exist (`POST /management/v1/users/machine`, scoped to its org)
and never touches one that does — see *What is not in git* for the boundary
this stops at. `desired.instanceMembers` grants or updates an explicit role
list per login through `/admin/v1/members`, separately from `reconcile_admins`'
hardcoded `IAM_OWNER` grant for `desired.admins`; a login in both lists fails
the run before either reconciler makes a call, because two reconcilers writing
different roles to the same membership would flap every 30 minutes.
`desired.allowedIamOwnerMachines` is a fail-closed report, not a fix: any
machine user holding instance `IAM_OWNER` that is not on the list stops the
run, the same read-only precedent as `assert_reserved_org_clean`. A live query
found exactly two such machine users — `iam-admin` (this reconciler's own
credential) and `svc-onboarding` (documented in `docs/onboarding-api.md`
9.1) — both seeded into the allowlist with a reason.

**Org memberships are asserted, not reconciled.** `desired.instanceMembers`
above writes to `/admin/v1/members` — that endpoint is scoped to *instance*
roles (`IAM_OWNER`, `IAM_LOGIN_CLIENT`, ...). An **org** membership such as
`ORG_OWNER_VIEWER` is a different resource with a different role vocabulary,
and its write endpoint — `POST /management/v1/orgs/members`, the shape every
other org-scoped reconciler here would suggest — returns
`{"code":5,"message":"Not Found"}` on this Zitadel v4.15.3, verified directly
against the live instance. Shipping that guessed path anyway would fail this
job every 30 minutes on a 404 that names the wrong problem. So
`assert_org_memberships` only reads, via
`POST /management/v1/users/{userId}/memberships/_search` with the
`x-zitadel-orgid` header (mandatory — omit it and the endpoint returns an
empty list rather than an error, indistinguishable from a revoked
membership), and fails the run naming the login and org if a declared
`desired.orgMemberships` entry is missing or its roles have drifted. The
membership itself is still granted by hand in the console, the same
"declared but not written" shape as the IdP client secret and the SMTP
password below.

### The skin applies to every org

The Aurora palette in `desired.labelPolicy` is set on the **instance** label
policy, which is what every org renders unless it has its own. An org-level
policy shadows it silently, for every login scoped to that org — which is how
the platform look forks without anyone noticing.

So the reconciler resets any org that has one back to the instance skin. Orgs
listed in `desired.selfBrandedOrgs` are exempt: per-tenant branding is a product
feature, and a customer who supplies their own logo and colours keeps them. Add
a tenant there the moment they brand themselves, or the next run reverts it.

The layout half of Aurora — the mesh, the glass card, the derived palette — is
in the login v2 fork, not in any policy, so it applies to every org regardless.

The reconciler is stdlib-only Python with its own suite; run it before changing
the logic, since a bug here rewrites the instance login policy:

```bash
python3 charts/apps/zitadel-bootstrap/files/bootstrap_test.py
```

**Branding is cached in the login pods.** Login v2 caches
`getBrandingSettings` for an hour per pod, so a colour or logo change stays
invisible on a live pod long after the API returns the new value — it looks
exactly like the change not having been saved. `login.env.API_CACHE_CONFIG` in
the Zitadel chart drops that to one minute. If branding still looks stale,
confirm against the rendered HTML, not the API:

```bash
curl -s https://auth.tesserix.app/ui/v2/login/loginname | grep -o '#[0-9A-Fa-f]\{6\}' | sort -u
```

## What is not in git

Configured live and not declared in this chart. Each one drifts silently, because
nothing reconciles it.

**SMTP — configured 2026-08-28, through Resend.** Until that date there was no
provider at all, which meant no email verification and **no password reset**: a
locked-out operator had no route back in. That gap is closed.

```
id             388266420867171601
senderAddress  auth@tesserix.app        senderName  Tesserix
host           smtp.resend.com:587      user        resend
tls            true                     state       SMTP_CONFIG_ACTIVE
password       prod-zitadel-resend-api-key (GCP Secret Manager, send-only Resend key)
```

Port **587 with STARTTLS**, not 465. Zitadel's `tls` flag drives STARTTLS, and
465 expects implicit TLS — the mismatch is a silent failure, not an error.

The key is deliberately **not** the platform-wide `prod-resend-api-key` that
mark8ly and fanzone share. Rotating that one for an unrelated product would take
out password reset for the whole identity platform, at exactly the moment someone
is trying to recover an account. `tesserix.app` is verified in Resend and already
serves `mark8ly-otto`, so a second key needed no DNS work.

`DefaultInstance` applies only at first instance creation, so the provider cannot
be *created* from the chart — but `zitadel-bootstrap` now **asserts** it through
`/admin/v1/smtp`, the same way it asserts the Google IdP. Sender, host, user and
`tls` are held to `desired.smtp`; a deactivated provider is reactivated; a missing
one fails the run, because creating it needs the password.

Two properties of this endpoint, both established against the live instance
rather than assumed:

- **Omitting `password` on `PUT` preserves the stored secret.** The change event
  carries no password key and mail keeps sending, so the reconciler owns the
  configuration while the credential stays in Secret Manager. Same rule as the
  IdP endpoint.
- **`description` is written but never projected.** It reaches the eventstore —
  `instance.smtp.config.changed` carries the new value — yet `GET` still returns
  the string set at creation, a day later. It is therefore sent on update and
  never compared; asserting it would report drift no write can clear. An earlier
  note here called it "ignored", which the event log disproves: the write lands,
  the read model just never reflects it.

**IdP connectors.** GitHub, Google, Okta and Entra are runtime objects bound to
an organization, not config — that binding is the reason Zitadel replaced
Keycloak. Create them per tenant through the API with the `iam-admin` machine
key, or in the console under *Organization → Identity Providers*.

Google sign-in works today, through **one org-level connector**, declared in
`zitadel-bootstrap` since 2026-08-28:

```
instance IdPs   none
instance policy allowExternalIdp=true, idps=[]

ZITADEL  org  login policy isDefault=false (CUSTOM), idps=[]   — no connector
TESSERIX org  login policy isDefault=false (CUSTOM), idps=[386381087862948767]
              IdP 386381087862948767 "Google" ACTIVE
              clientId 849928263410-ctrdo7o0sj68r4sddbf942bolunplc4e...
```

There were two until 2026-08-28. The ZITADEL org's connector
(`386336249998213772`, on its own separate OAuth client) had been detached from
that org's login policy on 2026-08-21 and left running with zero user links —
live, invisible, and still holding a client secret. Deleted under #676. Note the
delete path: a modern provider is `DELETE /management/v1/idps/templates/{id}`;
the legacy `/management/v1/idps/{id}` returns 404 for it.

**IdPs bind to organizations, never to projects.** A project only governs whether
an authenticated user gets a token (`projectRoleCheck`, role grants). And
**both orgs run custom login policies** (`isDefault=false`), so neither inherits
instance-level IdPs: an IdP created at instance level would appear **nowhere**
until each org policy named it or was reset to inherit.

**It stays org-level deliberately, and #676 was closed on that basis.** An
instance connector is inherited by every org that does not override it, including
the tenant orgs `zitadel-onboarding.md` creates — and tenants bring their own
IdP, so a Tesserix-owned Google button on a customer's login page is the wrong
default. The reason instance-level was originally wanted — an unscoped login
resolving the *default* org's connector, stranding humans linked elsewhere —
disappeared when `defaultOrg` became TESSERIX, which is where all the humans
already are.

`zitadel-bootstrap` now asserts the connector each run: it fixes option drift,
re-binds it to the login policy if that reference is lost, and fails the run on a
missing provider, an unexpected ID or a changed `clientId` — each of which needs
a client secret the reconciler deliberately does not hold.

Both connectors previously carried `isAutoCreation: true`, which contradicted
`allowRegister: false` and let any Google account self-provision a user. Turned
off on both 2026-08-28 (#675) while the platform was staff-only. **Reopened
2026-09-01 for consumer signup:** HomeChef customers self-register with email
or their own Google account, so the survivor now runs `isAutoCreation: true`,
`isCreationAllowed: true`, `isLinkingAllowed: true`,
`autoLinking: AUTO_LINKING_OPTION_EMAIL`, and `allowRegister: true` is asserted
on both the instance policy and the TESSERIX org's custom policy (orgs with a
custom `isDefault=false` policy never inherit the instance value — the new
`orgLoginPolicies` block in `zitadel-bootstrap` exists for exactly that).
Authorization now rests where it belongs: self-registered users hold no role
grants and no memberships; privileged surfaces are gated by role grants and
app-side RBAC, not by closed registration.

**`isAutoUpdate` is off on the TESSERIX connector, and must stay off.** With it
on, Zitadel rewrites the linked user's profile from Google's claims on *every*
federated sign-in. That is not theoretical: `instance-admin`'s display name was
edited in the console twice on 2026-08-28, reported saved both times, and both
times reverted to the Google account's name at the next login — the profile form
is not broken, it is being overwritten afterwards. Turned off the same day. The
cost is that a genuine rename at Google no longer propagates, which for a
break-glass account is the right way round.

All four of these options are false-by-default booleans, so Zitadel omits them
from the API response entirely — `isAutoUpdate: false` reads back as *absent*,
not as `false`. Any reconciler must treat absent as false or it will re-assert
them forever; see the `drift_between` docstring in `zitadel-bootstrap` for the
same trap that produced the 0s `passwordCheckLifetime` login loop. That is
exactly what `reconcile_org_idps` reuses, and `test_absent_false_option_is_not_drift`
is there to keep it that way.

**Updating an IdP does not blank its secret, as long as you omit the field.** An
earlier revision of this document warned that "the update endpoint replaces the
whole config including the secret, so reconciling from git blanks it unless the
secret is supplied". That is only true if you *send* a `clientSecret`. Omit it
and the stored value is untouched — proven against the eventstore when #675 flipped
the flags above:

```
2026-08-28  org.idp.google.changed   386381087862948767   clientSecret in payload = f
2026-08-15  org.idp.google.changed   386381087862948767   clientSecret in payload = f
2026-08-15  org.idp.google.added     386381087862948767   clientSecret in payload = t
```

Only the original `added` event carries it. So a reconciler can assert an IdP's
non-secret configuration without ever holding the secret — which is what makes
declaring these in `zitadel-bootstrap` practical. Supplying an empty or wrong
secret is still destructive; omitting the field is not.

**Machine user credentials.** `zitadel-bootstrap` now creates a declared machine
user's *account* (`desired.machineUsers`, see above) and reconciles who holds
what instance membership, but it never creates or holds the account's
*credential*. A PAT or a machine key can only be read once, at the moment it is
issued — Zitadel does not let you fetch an existing one again — so there is no
API call this reconciler could make on a schedule that would keep a credential
current the way it keeps a label policy current. Issuing the key still happens
by hand in the console (*Users → Service Users → \<user\> → Keys → New*, or
*Personal Access Tokens → New*) and the value still goes into GCP Secret
Manager by hand, exactly as before this change. What changed is narrower than
it might read: the account and its instance-level grants are now asserted from
git; the one-time secret that authenticates as that account is not, and cannot
be without Zitadel exposing a re-issuable credential, which it does not.

**`console-identity-reader`** (userId `388843516966469647`, org `TESSERIX`) is
the console's cross-product identity lookup credential (tesserix-home#211,
feeding #134). Declared in `desired.machineUsers` and its membership in
`desired.orgMemberships`; both are asserted, not reconciled — see *Branding,
login policy and admins are reconciled* above for why the membership write
path specifically is not attempted.

```
membership   ORG_OWNER_VIEWER on TESSERIX (an ORG membership, not instance)
PAT          prod-console-identity-reader-pat (GCP Secret Manager), synced to
             the console Deployment as ZITADEL_IDENTITY_READER_PAT
verified     lists all 8 TESSERIX users; DENIED at instance level
             (/admin/v1/members/_search → "No matching permissions found");
             DENIED writing (self-grant of IAM_OWNER → HTTP 403)
```

**Scoping decision.** Zitadel has no user-only reader role — the narrowest
read-only *org* membership is `ORG_OWNER_VIEWER`, which reads everything in
TESSERIX, not just users. `IAM_OWNER_VIEWER` (instance-wide read) was
considered and rejected: it would read every org on the instance, including
ZITADEL's own console configuration, for a lookup that only ever needs
TESSERIX. `ORG_OWNER_VIEWER` on TESSERIX is the closer-fitting over-grant of
the two.

No per-secret GCP IAM binding was added for this PAT:
`roles/secretmanager.secretAccessor` is already held project-wide by the ESO
service accounts, which is why no other `prod-console-*` secret carries one
of its own either.

**Actions.** Custom claims, token enrichment and provisioning hooks are Actions
v2 objects, created through the API.

## Alerting

`zitadel-alerts` covers the API and login deployments; `zitadel-postgres-alerts`
covers the database on the same rule set as the rest of the estate. Both use
`absent()` rather than `== 0` for liveness, because a Deployment scaled to zero
or an evicted pod emits no series at all and an equality check never fires on a
missing series — the failure mode that hid the 2026-05-12 outage for five weeks.

## Licence

Zitadel is **AGPL-3.0-only**, with exceptions: `proto/` and `apps/docs/` are
Apache 2.0, and `apps/login/`, `packages/zitadel-client`, `packages/zitadel-proto`
are MIT. Running an unmodified image over a network is fine; modifying the
server source and offering it as a service triggers the AGPL source
obligation.

## Per-product access control

`ZitadelProject.spec.access` declares a product's audience (operator feature, 2026-09-01). Absent or `mode: public` means any signed-in org user can authenticate; the operator heals `projectRoleCheck` off. `mode: restricted` with `members: [{email, roles?}]` turns `projectRoleCheck` on and reconciles user grants to exactly that list — additions, role updates, and pruning of stale grants. Roles default to `member` and are auto-created on the project.

Rules of thumb: restriction is per Zitadel project, not per application, so a separately-restricted product needs its own `ZitadelProject` claim; members must already have signed up (the claim goes `Ready=False` naming the email otherwise); org signup itself stays open — gating happens at token issuance.
