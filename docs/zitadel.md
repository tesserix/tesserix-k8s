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
| `prod-zitadel-admin-password` | `zitadel-admin-password` | first-instance human admin |
| `prod-zitadel-login-service-crt` / `-key` | `zitadel-login-service-key` | login v2 → API |

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
- `zitadel-admin`, the break-glass password admin — the only way back in when an
  IdP misroutes a federated login.

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

Three things cannot be declared in this chart, and the instance is not
production-ready until they are done in the console.

**SMTP.** `DefaultInstance` applies only at first instance creation, so the
provider is configured under *Instance → Notifications → SMTP provider* — host,
port, sender and password all entered there, not through the chart. Until then
there is no email verification and no password reset, so a locked-out user has
no route back in.

**IdP connectors.** GitHub, Google, Okta and Entra are runtime objects bound to
an organization, not config — that binding is the reason Zitadel replaced
Keycloak. Create them per tenant through the API with the `iam-admin` machine
key, or in the console under *Organization → Identity Providers*.

The Google IdP on the ZITADEL org is deliberately outside `zitadel-bootstrap`:
its update endpoint replaces the whole config including the client secret, and
that secret was typed into the console and never stored in Secret Manager, so
reconciling it from git would blank it. Put the secret in Secret Manager first
if this ever needs to be declared.

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
