# CloudNativePG Migration Guide

Reference guide for migrating Tesserix products from standalone PostgreSQL StatefulSets to CloudNativePG (CNPG).

---

## 1. Overview

**Before:** Each product ran a single PostgreSQL StatefulSet in a dedicated `postgresql-{product}` namespace. No HA, no automated failover, no WAL archiving, manual backups only.

**After:** Each product gets a CNPG `Cluster` resource in its own app namespace (e.g., `homechef`, `fanzone`, `global`). The CNPG operator (v1.24.1, running in `cnpg-system`) manages:

- 3-instance HA (1 primary + 1 synchronous replica + 1 asynchronous replica)
- Automated failover with zero-data-loss guarantees (synchronous replication)
- Continuous WAL archiving to GCS via Barman Cloud
- Auto-managed TLS (TLS 1.3, self-signed CA, automatic rotation)
- Built-in Prometheus monitoring (port 9187)
- PodDisruptionBudgets for safe node drains

The old `postgresql-{product}` namespaces are decommissioned after migration.

---

## 2. Chart Structure

Each product has a Helm chart at:

```
charts/apps/{product}-postgres/
  Chart.yaml
  values.yaml
  templates/
    cluster.yaml
    externalsecret.yaml
```

### Templates

`cluster.yaml` and `externalsecret.yaml` are identical across most products (homechef, global, fanzone, gameverse, hms, bookkeeping, devai, scrapper, stockpilot). Only `mark8ly-postgres` differs because it bootstraps two databases with separate owners.

**cluster.yaml** renders a `postgresql.cnpg.io/v1 Cluster` resource with:

- Bootstrap via `initdb` (database, owner, secret, optional `postInitSQL` for additional databases)
- Separate data and WAL volumes for I/O isolation
- PostgreSQL parameter tuning
- Synchronous replication (`minSyncReplicas: 1`, `maxSyncReplicas: 1`)
- Conditional backup block (Barman Cloud to GCS with gzip compression)
- Conditional `serviceAccountTemplate` for Workload Identity (only when backup is enabled)
- Pod anti-affinity (preferred), unsupervised primary update strategy, PDB enabled

**externalsecret.yaml** creates a `kubernetes.io/basic-auth` secret from GCP Secret Manager:

- References `bootstrap.gcpSecretName` in values
- Uses `ClusterSecretStore` named `gcp-secret-store`
- Produces a secret with `username` and `password` keys (CNPG basic-auth format)

### Key values.yaml Fields

```yaml
namespace: homechef                          # App namespace (not a separate PG namespace)
clusterName: homechef-postgres
instances: 3                                 # 1 primary + 2 replicas
imageName: ghcr.io/cloudnative-pg/postgresql:16.4
storageSize: 60Gi
storageClass: standard-rwo-retain
walStorageSize: 10Gi

bootstrap:
  database: homechef_db                      # Primary database
  owner: homechef                            # Primary role
  secret: homechef-postgres-app-credentials  # basic-auth secret name
  gcpSecretName: prod-homechef-postgresql-password
  postInitSQL: []                            # Additional CREATE DATABASE statements

backup:
  enabled: true
  destinationPath: "gs://tesseract-prod-backups-in/homechef-postgres"
  retentionPolicy: "30d"
  serviceAccount: "app-secrets-homechef-prod@tesseracthub-480811.iam.gserviceaccount.com"

replication:
  minSyncReplicas: 1
  maxSyncReplicas: 1
```

---

## 3. ArgoCD App

Each CNPG cluster has an ArgoCD Application at:

```
argocd/prod/apps/{product-group}/{product}-postgres.yaml
```

Example (`homechef-postgres.yaml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homechef-postgres
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: homechef
  source:
    repoURL: https://github.com/tesserix/tesserix-k8s.git
    targetRevision: HEAD
    path: charts/apps/homechef-postgres
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: homechef
  syncPolicy:
    automated:
      prune: false       # NEVER auto-delete database resources
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

Key points:

- `prune: false` prevents ArgoCD from deleting PVCs or Cluster resources if they disappear from Git
- `ServerSideApply` is required for CNPG's large CRD spec
- `RespectIgnoreDifferences` avoids spurious drift from operator-managed fields
- `resources-finalizer` ensures cleanup only happens through explicit deletion

---

## 4. NetworkPolicy Requirements

The CNPG operator (in `cnpg-system`) must be able to reach CNPG pods on port 8000 for health checks and status updates. Without this, replicas will never become ready.

Every namespace that hosts a CNPG cluster must allow ingress from `cnpg-system`. This is defined in:

```
charts/thirdparty/istio-config/templates/network-policies.yaml
```

The relevant ingress rule:

```yaml
# Allow from cnpg-system (CloudNativePG operator status checks on port 8000)
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: cnpg-system
```

If you add a new namespace with a CNPG cluster, you must add this rule to the namespace's NetworkPolicy in the istio-config chart. Without it, the operator times out on health checks, and `kubectl get cluster` will show replicas stuck in `joining` state indefinitely.

---

## 5. Data Migration Steps

Run the old PostgreSQL and CNPG cluster in parallel during migration.

### Step 1: Deploy CNPG Cluster

Push the chart and ArgoCD app. Wait for the cluster to become healthy:

```bash
kubectl get cluster -n {namespace}
# STATUS should be "Cluster in healthy state" with {instances}/{instances} ready
```

### Step 2: Verify Cluster Health

```bash
kubectl get pods -n {namespace} -l cnpg.io/cluster={product}-postgres
# All 3 pods should be Running and 1/1 Ready
```

### Step 3: Dump and Restore

**Option A: Direct connection from CNPG pod to old PG** (works when egress to the old PG namespace is allowed):

```bash
kubectl exec -n {namespace} -c postgres {product}-postgres-1 -- sh -c "
  export PGPASSWORD='{old_password}'
  pg_dump -h postgresql.postgresql-{product}.svc.cluster.local \
    -U {old_user} -d {db_name} \
    --no-owner --no-acl -Fc \
    -f /controller/tmp/dump.dump

  export PGPASSWORD='{cnpg_password}'
  pg_restore -h localhost -U {cnpg_user} -d {db_name} \
    --no-owner --no-acl --clean --if-exists \
    /controller/tmp/dump.dump

  rm /controller/tmp/dump.dump
"
```

**Option B: Pipe between pods** (when NetworkPolicy blocks direct access):

```bash
kubectl exec -n postgresql-{product} postgresql-0 -- \
  pg_dump -U {old_user} -d {db_name} --no-owner --no-acl -Fc \
| kubectl exec -i -n {namespace} -c postgres {product}-postgres-1 -- \
  pg_restore -h localhost -U {cnpg_user} -d {db_name} \
    --no-owner --no-acl --clean --if-exists
```

For clusters with multiple databases (global has 12, fanzone has 3), repeat for each database.

### Step 4: Verify Data

```bash
# Count tables and rows in both old and new
kubectl exec -n postgresql-{product} postgresql-0 -- \
  psql -U {user} -d {db_name} -c "SELECT schemaname, tablename FROM pg_tables WHERE schemaname='public';"

kubectl exec -n {namespace} -c postgres {product}-postgres-1 -- \
  psql -U {user} -d {db_name} -c "SELECT schemaname, tablename FROM pg_tables WHERE schemaname='public';"
```

### Step 5: Update API Connection String

Change the service's database host from:
```
postgresql.postgresql-{product}.svc.cluster.local:5432
```
to:
```
{product}-postgres-rw.{namespace}.svc.cluster.local:5432
```

This is typically in the service's `values-prod.yaml` or ExternalSecret environment variables.

### Step 6: Update db-schema-bootstrap

Update the `db-schema-bootstrap` chart to point at the new CNPG host for this product's schemas.

### Step 7: Verify API Health

```bash
kubectl logs -n {namespace} -l app={product}-api --tail=50
# Confirm successful DB connection and health check passing
```

### Step 8: Decommission Old PostgreSQL

1. Remove the old PostgreSQL ArgoCD app (e.g., `homechef-postgresql`)
2. Delete the old namespace: `kubectl delete namespace postgresql-{product}`
3. Verify PVCs are released (the old StatefulSet used `standard-rwo`, not `standard-rwo-retain`)

---

## 6. Storage Class Change / Rolling PVC Replacement

CNPG does not support changing `storageClass` on existing PVCs. To migrate storage class (e.g., from `standard-rwo` to `standard-rwo-retain`):

### Step 1: Update values.yaml

```yaml
storageClass: standard-rwo-retain
```

### Step 2: Push and Sync

Commit, push, and let ArgoCD sync. The Cluster spec will update but existing PVCs remain unchanged.

### Step 3: Replace Replica PVCs One at a Time

For each replica (not the primary):

```bash
# Delete the replica pod and its PVCs
kubectl delete pvc {product}-postgres-{N} -n {namespace}
kubectl delete pvc {product}-postgres-{N}-wal -n {namespace}
kubectl delete pod {product}-postgres-{N} -n {namespace}

# CNPG will recreate the pod and PVCs with the new storage class
# Wait for the replica to rejoin and sync
kubectl get cluster -n {namespace} -w
```

### Step 4: Switchover Primary

Once all replicas are on the new storage class, promote a replica:

```bash
kubectl patch cluster {product}-postgres -n {namespace} \
  --type merge \
  -p '{"status":{"targetPrimary":"{product}-postgres-{new-instance}"}}' \
  --subresource=status
```

Wait for the switchover to complete.

### Step 5: Replace Old Primary PVCs

```bash
kubectl delete pvc {product}-postgres-{old-primary} -n {namespace}
kubectl delete pvc {product}-postgres-{old-primary}-wal -n {namespace}
kubectl delete pod {product}-postgres-{old-primary} -n {namespace}
```

### Step 6: Verify

```bash
kubectl get pvc -n {namespace} -l cnpg.io/cluster={product}-postgres
# All PVCs should show the new storage class
```

---

## 7. Service Endpoints

CNPG creates three Service resources per cluster:

| Service | DNS | Purpose |
|---------|-----|---------|
| `{product}-postgres-rw` | `{product}-postgres-rw.{namespace}.svc.cluster.local` | Primary only (read-write) |
| `{product}-postgres-ro` | `{product}-postgres-ro.{namespace}.svc.cluster.local` | Read replicas only |
| `{product}-postgres-r` | `{product}-postgres-r.{namespace}.svc.cluster.local` | Any instance (read) |

- **Port:** 5432
- **TLS:** Required. CNPG enforces TLS 1.3 with auto-managed certificates. Clients must use `sslmode=require` (or `verify-ca` / `verify-full` if they have the CA cert).
- **Connection string format:** `postgresql://{user}:{password}@{product}-postgres-rw.{namespace}.svc.cluster.local:5432/{db_name}?sslmode=require`

---

## 8. Products Migrated

| Product | Namespace | Cluster Name | Databases | Instances | Storage | Backup |
|---------|-----------|-------------|-----------|-----------|---------|--------|
| HomeChef | `homechef` | `homechef-postgres` | `homechef_db` | 3 | 60Gi | Yes |
| Global | `global` | `global-postgres` | `global_db`, `keycloak_customer`, `keycloak_internal`, `tenants_db`, `notifications_db`, `subscriptions_db`, `documents_db`, `verifications_db`, `onboarding_content_db`, `custom_domains_db`, `location_db`, `tenant_router_db`, `kora_db` | 3 | 20Gi | Yes |
| Fanzone | `fanzone` | `fanzone-postgres` | `fanzone`, `fanzone_auth`, `fanzone_db` | 3 | 10Gi | Yes |
| GameVerse | `gameverse` | `gameverse-postgres` | `gameverse` | 3 | 10Gi | No |
| HMS | `hms` | `hms-postgres` | `hms_db` | 3 | 10Gi | Yes |
| Bookkeeping | `bookkeeping` | `bookkeeping-postgres` | `bookkeeping_db` | 3 | 10Gi | Yes |
| DevAI | `devai` | `devai-postgres` | `devai_db` | 3 | 10Gi | Yes |
| Scrapper | `scrapper` | `scrapper-postgres` | `scrapper_db` | 3 | 10Gi | No |
| StockPilot | `stockpilot` | `stockpilot-postgres` | `stockpilot` | 3 | 10Gi | No |
| Mark8ly | `mark8ly` | `mark8ly-postgres` | `mark8ly_platform_api`, `mark8ly_openfga` | 1 | 20Gi | Yes |

Products with `Backup: No` (gameverse, scrapper, stockpilot) do not have GCS WAL archiving configured and do not render the `serviceAccountTemplate` block.

---

## 9. Gotchas

**Superuser access is disabled.** CNPG sets `enableSuperuserAccess: false`. Extensions that require superuser (`dblink`, `postgres_fdw`, `pg_stat_statements` if not pre-installed) cannot be installed by the application role. The CNPG image includes common extensions, but custom ones need a custom image.

**Read-only filesystem.** CNPG pods have a read-only root filesystem. The only writable paths are `/controller/tmp` (ephemeral) and the data/WAL volumes. Use `/controller/tmp` for dump files during migration.

**Keycloak databases are large.** The `keycloak_customer` and `keycloak_internal` databases (in `global-postgres`) are approximately 15MB each. `pg_restore` on `standard-rwo` can take several minutes.

**Instance numbers never reset.** After rolling PVC replacements, CNPG increments instance numbers. A cluster that started as instances 1,2,3 may end up as 7,8,9. This is normal. Do not try to force instance numbers back to 1,2,3.

**ExternalSecret uses `bootstrap.gcpSecretName`.** The `externalsecret.yaml` template reads the GCP Secret Manager secret name from `bootstrap.gcpSecretName` in values. If this value is wrong or the GCP secret does not exist, the CNPG Cluster will fail to start because the basic-auth secret will be empty.

**Backup-conditional serviceAccountTemplate.** When `backup.enabled` is `false`, the `serviceAccountTemplate` block is not rendered. This means the pod's K8s ServiceAccount won't have a Workload Identity annotation. If you later enable backup, you must also ensure the GCS bucket exists and the GCP SA has `roles/storage.objectAdmin`.

**NetworkPolicy is mandatory.** If the `cnpg-system` namespace is not allowed in the ingress NetworkPolicy of the target namespace, the CNPG operator cannot reach pods on port 8000. Replicas will never transition from `joining` to `streaming`. This is the single most common cause of CNPG clusters appearing stuck.

**`prune: false` in ArgoCD.** The ArgoCD app intentionally sets `prune: false`. This prevents accidental deletion of the CNPG Cluster, PVCs, or Secrets if a chart change removes them from the rendered manifests. Manual cleanup is required when decommissioning.

**Mark8ly uses a different chart structure.** `mark8ly-postgres` has a custom `cluster.yaml` and additional templates (`post-init-job.yaml`, `marketplace-api-bootstrap-job.yaml`) because it manages two databases with separate owners and passwords. Do not copy the mark8ly templates for new products; use the standard template from any other product (e.g., `homechef-postgres`).
