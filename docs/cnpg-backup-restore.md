# CNPG Backups & Restore — self-managed, GCS, 90-day retention

How PostgreSQL backups work across the Tesserix CNPG clusters, and how to
restore. Worked example: `homechef-postgres` (namespace `homechef`). The same
pattern applies to every `charts/apps/*-postgres/` cluster.

## What runs automatically (no human action)

Backups are fully self-managed by the CloudNativePG operator:

1. **Continuous WAL archiving.** Every WAL segment is compressed (gzip) and
   pushed to GCS as soon as it is closed (`barmanObjectStore` in the `Cluster`
   spec). This is what makes point-in-time recovery (PITR) possible.
2. **Scheduled base backups.** A `ScheduledBackup` runs **twice daily**
   (02:00 & 14:00 UTC), `method: barmanObjectStore`, `target: prefer-standby`
   (runs on a replica so the primary is never loaded).
3. **Retention pruning.** `retentionPolicy: "90d"` — Barman keeps a **90-day
   recovery window** and prunes older base backups *together with the WAL they
   anchor*, so the recovery chain is never left broken.
4. **Credentials.** GCS access is via Workload Identity
   (`serviceAccountTemplate` → `app-secrets-homechef-prod@…`), no static keys.

### Storage layout (GCS)

Shared bucket `gs://tesseract-prod-backups-in/`, one prefix per cluster:

```
gs://tesseract-prod-backups-in/homechef-postgres/homechef-postgres/
  ├── base/<timestamp>/    # base backups
  └── wals/                # archived WAL segments
```

### Retention — two aligned layers (both = 90 days)

| Layer | Mechanism | Behaviour |
|-------|-----------|-----------|
| **CNPG / Barman** (primary) | `retentionPolicy: "90d"` | Chain-aware. Deletes base backups + their WAL together. **This is the real retention.** |
| **GCS bucket lifecycle** (backstop) | bucket-wide `Delete age=90d` (+ noncurrent-version cleanup) | Dumb age-based delete; catches any orphan CNPG missed. Already configured on the bucket. |

> The bucket also tiers objects STANDARD→NEARLINE(7d)→COLDLINE(15d)→ARCHIVE(30d)
> for cost. Note ARCHIVE has a 365-day minimum-storage charge, so deleting at
> 90d incurs a small early-deletion fee — acceptable for safety, and applies
> bucket-wide (not homechef-specific).

Keep the two layers equal (90/90). If you ever lengthen one, lengthen
**CNPG retention first** — never let the GCS lifecycle delete objects that CNPG
still considers in-window.

## Verify backups are healthy

```bash
export KUBECONFIG=~/.kube/gke-prod

# CNPG-reported recovery window + last good backup
kubectl get cluster homechef-postgres -n homechef \
  -o jsonpath='{"first: "}{.status.firstRecoverabilityPoint}{"  last: "}{.status.lastSuccessfulBackup}{"\n"}'

# Backup objects + their result
kubectl get backups.postgresql.cnpg.io -n homechef

# Objects actually in GCS
gcloud storage ls gs://tesseract-prod-backups-in/homechef-postgres/homechef-postgres/base/

# Continuous-archiving health is alerted by CNPGWALArchiveFailing
# (see charts/apps/homechef-postgres/templates/prometheusrule.yaml)
```

A scheduled backup **failing** while `target: prefer-standby` and the cluster
has **no healthy standby** is expected (there is nowhere to run it). Keeping the
cluster healthy (3/3) — which the autoheal CronJob now does automatically —
keeps scheduled backups green.

## Restore

CNPG never restores in place. You **bootstrap a new cluster** from the object
store, verify it, then cut over. Both forms below leave the original untouched.

### A. Full restore (latest consistent point)

Create a new cluster that recovers from the backup store:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: homechef-postgres-restore
  namespace: homechef
spec:
  instances: 1
  storage: { size: 100Gi, storageClass: standard-rwo-retain }
  walStorage: { size: 30Gi, storageClass: standard-rwo-retain }
  bootstrap:
    recovery:
      source: homechef-postgres
  externalClusters:
    - name: homechef-postgres
      barmanObjectStore:
        destinationPath: "gs://tesseract-prod-backups-in/homechef-postgres"
        googleCredentials: { gkeEnvironment: true }
        wal: { compression: gzip }
  serviceAccountTemplate:
    metadata:
      annotations:
        iam.gke.io/gcp-service-account: app-secrets-homechef-prod@tesseracthub-480811.iam.gserviceaccount.com
```

### B. Point-in-time recovery (PITR)

Same as above, but pin a target under `bootstrap.recovery`:

```yaml
  bootstrap:
    recovery:
      source: homechef-postgres
      recoveryTarget:
        targetTime: "2026-06-17 01:30:00+00"   # any time within the 90-day window
```

Other targets: `targetLSN`, `targetXID`, `targetName` (a restore point).

### Cut over after verifying the restored data

```bash
# 1. Point the app at the restored cluster's -rw service, OR
# 2. Rename: scale the app down, repoint, scale up. Keep the old cluster until
#    the restore is confirmed good, then delete it.
```

> Restore reads base backups + WAL from GCS. Postgres backups stay in STANDARD
> for their whole life, so there is no retrieval fee or restore delay — but the
> recovery window is only **3 days** (one daily base backup, latest three kept).
> Anything older is gone; there is no fallback copy.

## Where it's configured

- Backup + WAL archive + retention: `charts/apps/homechef-postgres/templates/cluster.yaml` (`spec.backup`) and `values.yaml` (`backup.*`)
- Schedule: `charts/apps/homechef-postgres/templates/scheduled-backup.yaml`
- Archive-failure alert: `charts/apps/homechef-postgres/templates/prometheusrule.yaml` (`CNPGWALArchiveFailing`)
- GCS bucket lifecycle: `gs://tesseract-prod-backups-in` (project `tesseracthub-480811`)
