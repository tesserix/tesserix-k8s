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

`auth.tesserix.app` must also be listed in `frontendApps` in
`argocd/prod/infrastructure/istio-auth-policies.yaml`. That allowlist is
enforced at the ingress gateway, before any policy in this namespace is
consulted, and a missing host answers every request with `403 RBAC: access
denied` no matter how healthy the pods are.

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

Backups write to `gs://tesserix-cnpg-backups/zitadel` at 02:30 daily with 30-day
retention. They depend on an `iam.workloadIdentityUser` binding for
`cnpg-backup@tesseracthub-480811.iam.gserviceaccount.com` on
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
- `Features.LoginV2.Required: true` — login v1 is deprecated upstream.
- `LockoutPolicy` 10 attempts — upstream ships `0`, meaning no lockout at all.
- `PasswordComplexityPolicy.MinLength: 12`.

Per-organization policy overrides everything here, so a tenant can force MFA or
disable password login without touching this file.

## What is not in git

Three things cannot be declared in this chart, and the instance is not
production-ready until they are done in the console.

**SMTP.** `DefaultInstance` applies only at first instance creation, so the
provider is configured under *Instance → Notifications → SMTP provider*. The
password is already mounted as `ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_SMTP_PASSWORD`
from `prod-zitadel-smtp-password`; only the host, port and sender need entering.
Until then there is no email verification and no password reset, so a locked-out
user has no route back in.

**IdP connectors.** GitHub, Google, Okta and Entra are runtime objects bound to
an organization, not config — that binding is the reason Zitadel replaced
Keycloak. Create them per tenant through the API with the `iam-admin` machine
key, or in the console under *Organization → Identity Providers*.

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
