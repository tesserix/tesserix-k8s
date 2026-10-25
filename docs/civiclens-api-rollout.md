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

## Writing-assist gateway

The API calls the dedicated `agentgateway-system/civiclens-ai` gateway with
`civiclens-ai-gateway-key`. Images before the assist release reject unknown
`secrets.json` fields, so order matters:

1. Kargo promotes a `tesserix/civiclens` image that includes `POST /v1/assist`;
   confirm it is running before step 3.
2. Merge the gateway configuration. Argo reconciles the namespace-bound OpenBao
   reader and seeder roles. The gateway PreSync job creates its credential with
   compare-and-set version 0 and preserves existing values; it never logs the key.
   Both API and gateway ExternalSecrets read this one production path.
3. Argo automatically syncs the gateway and API. The seed job retries if the
   OpenBao bootstrap has not reconciled yet. Check ExternalSecret readiness.
4. Apply the additive `12-vertex` Workload Identity binding for
   `agentgateway-system/civiclens-ai` through the reviewed Terraform plan.
5. Verify `/v1/capabilities` reports `assist: true` and a signed-in "Fix spelling"
   succeeds. Gateway requests without the client key must get 401.

Rollback is removing `CIVICLENS_AI_GATEWAY_URL`; assist then reports unavailable.

## Recovery

A failed migration leaves the previous ReplicaSet serving; fix the cause and
resync, the migrations are idempotent. Never drop the shared cluster, database or
schema as rollback; the CNPG `Database` reclaim policy is `retain`. Restore into
an isolated cluster and export only CivicLens data if recovery is needed.

Social publishing stays disabled (`CIVICLENS_PUBLISHING_ENABLED=false`) until a
real Page, scoped credentials and verified authority records exist.

## Community links

The CivicLens VirtualService also admits the two exact `/.well-known/` association
documents, UUID-shaped `/community/{id}` pages and `/assets/civiclens.png` to the
same API service. Health/readiness probes and unrelated assets stay in-cluster.
The API only renders independently approved community cards and serves reviewed
public text, never account responses or private report data. Existing upload
deadlines, session checks and disabled gateway retries remain in force.

Before calling app links ready, verify the public Apple association contains
`2CRHRRYBPL.app.tesserix.civiclens`, and register the actual Google Play app-signing
SHA-256 certificate in the application's `shared/app-links.json`. An empty Android
association list is intentional until that certificate is verified. Public store
download buttons remain disabled until each listing is actually available.
