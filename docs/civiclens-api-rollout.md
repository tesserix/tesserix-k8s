# CivicLens API production rollout

`civiclens-api` serves `https://civiclns-api.tesserix.app/v1/` through the shared
`istio-ingress/tesseract-gateway`. It uses `civiclens_db` on `global/global-postgres`
and does not create another Postgres cluster. Delivery follows Roamie:

| Repo | Owns |
|---|---|
| `tesserix/civiclens` | API code, image CI, `deploy-<sha>` tags in GAR `global/civiclens-api` |
| `tesserix/kargo-manifests` | `projects/civiclens/` Project, Warehouse and `prod` Stage |
| `tesserix/tesserix-k8s` | `charts/apps/civiclens-api`, Argo apps, ESO readers, Istio config |

## Approval gate

Do not merge until approval explicitly covers the new database, the two roles,
schema migrations and runtime grants. Identity approval does not cover this.
Immediately before merge, confirm the current kube context, CNPG health, a recent
successful backup and free storage.

## Credentials

An authorized OpenBao writer creates three KV v2 records under
`kv/civiclens/prod/app/`, property `value`, with compare-and-set version 0 and
without printing them:

- `civiclens-db-runtime-password` and `civiclens-db-migrator-password`: distinct
  random hex strings (`openssl rand -hex 32`), so no URL encoding is needed.
- `civiclens-identity-key`: at least 32 random characters. Rotating it remaps
  pseudonymous identities, so it needs its own reviewed migration.

Readers follow the Roamie model: `civiclens-production-reader` with role
`read-civiclens-<namespace>-production` in `civiclens` and `global`, read-only.
`global` gets the two passwords for CNPG; `civiclens` also gets the identity key.
Runtime pods mount only `civiclens-api-config`; the migration Job mounts only
`civiclens-migration-config`. No product secret lives in GCP Secret Manager.

`external-secrets/prod/civiclens-postgres-ca.yaml` pushes only `ca.crt` of the
CNPG-managed `global-postgres-ca` into `civiclens` hourly, so CA rotation needs
no manual step. `ca.key` never leaves `global`.

## Order

1. Merge; ArgoCD reconciles OpenBao roles, CNPG roles/database, istio-config and
   the readers. CNPG creates both roles once their password Secrets exist;
   confirm both exist before the first API sync, because migration 0004 skips
   the grants when `civiclens_runtime` is missing.
2. `civiclens-app-of-apps` creates `civiclens-api` and `civiclens-istio`.
3. Each sync runs `civiclens-api-migrate` (Sync hook, wave -1) with the migrator
   credential. Migration `0004_runtime_grants.sql` grants `civiclens_runtime`
   its DML. The Deployment only rolls after the hook succeeds.
4. Kargo promotes new `deploy-<sha>` images by writing `image.tag`/`image.digest`
   onto the `civiclens-api` Application.
5. Verify: `/v1/capabilities` 200, `/v1/me` and `/v1/reports` 401 without a
   session, then a real Google/Apple login from the app on two accounts.

## Recovery

A failed migration leaves the previous ReplicaSet serving; fix the cause and
resync, the migrations are idempotent. Never drop the shared cluster, database or
schema as rollback; the CNPG `Database` reclaim policy is `retain`. Restore into
an isolated cluster and export only CivicLens data if recovery is needed.

Social publishing stays disabled (`CIVICLENS_PUBLISHING_ENABLED=false`) until a
real Page, scoped credentials and verified authority records exist.
