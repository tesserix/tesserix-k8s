# homechef-postgres — Backup & Disaster-Recovery Runbook

Covers the `homechef-postgres` CNPG cluster (namespace `homechef`, prod cluster
`tesseract-prod-in-gke`). Closes issue Home-Chef-App#16.

> Note: the original issue said "Cloud SQL db-f1-micro". The prod homechef DB is
> **not** Cloud SQL — it is a **CloudNativePG (CNPG) cluster on GKE** (operator
> 1.24.1, PostgreSQL 16.4, 3 instances). This runbook reflects reality.

## Backup configuration (verified)

| Property | Value |
|---|---|
| Method | CNPG Barman object store (`barmanObjectStore`) |
| Destination | `gs://tesseract-prod-backups-in/homechef-postgres/homechef-postgres/` |
| Auth | GKE Workload Identity (`app-secrets-homechef-prod@…gserviceaccount.com`) |
| Base backups | `ScheduledBackup` `homechef-postgres-scheduled-backup` (multiple/day) |
| WAL archiving | Continuous, gzip, `archive_timeout = 300s` |
| Retention | 90 days |
| Recoverability window | `firstRecoverabilityPoint` … `lastSuccessfulBackup` (≈31d at time of writing) |
| Archiver health | `pg_stat_archiver`: 612 archived, 2 lifetime failures |

## RTO / RPO

- **RPO ≈ 5 minutes.** Bounded by `archive_timeout = 300s` — WAL is force-archived
  every 5 min even at low write volume. Worst case (all 3 instances + their PVCs
  lost simultaneously, recover from object store only) = up to the last archived
  WAL segment, ≤5 min. With ≥1 surviving replica, RPO ≈ 0 (streaming replication).
- **RTO ≈ 5 minutes** for the current ~13 MB DB. Measured in the drill below:
  base-backup restore 2s + WAL replay to consistency ~44s. A full CNPG recovery
  *cluster* adds pod scheduling + PVC provision + image pull (~2–4 min). Grows with
  DB size and WAL volume to replay.

## Restore drill (validated 2026-06-18) ✅

A non-prod restore was executed as a self-contained Job in the `homechef`
namespace, reusing the cluster's Workload-Identity SA for **read-only** access to
the backup bucket. It restored the latest base backup, replayed archived WAL to a
consistent state, brought PostgreSQL up on a scratch volume, and validated the
data against the live prod baseline:

| Check | Restored | Prod baseline | Match |
|---|---|---|---|
| public tables | 69 | 69 | ✅ |
| db size | 13 MB | 13 MB | ✅ |
| `users` rows | 18 | (live) | ✅ present |
| `orders` rows | 7 | (live) | ✅ present |

**Safety guarantees of the drill:** read-only against the bucket; the recovery
instance ran with `archive_mode=off` (cannot write WAL back to the prod bucket),
`listen_addresses=localhost`, scratch `emptyDir`, and was torn down on completion.
It never touched the live cluster or `homechef_db`.

### CNPG-standalone restore gotchas
A restored CNPG `PGDATA` references operator-managed paths under `/controller`
(certs, hba/ident, logs, socket) that don't exist outside a CNPG pod. To start it
standalone, override at boot: `ssl=off`, `hba_file`/`ident_file` (minimal trust
hba), `logging_collector=off`, `unix_socket_directories=/tmp`. The drill manifest
(`/tmp/dr-restore-drill.yaml`) captures the full sequence.

## Production recovery procedure (real DR)

For an actual recovery, **do not** hand-roll standalone postgres — create a CNPG
recovery cluster so networking/Istio/WI/certs are wired correctly:

1. Create a `Cluster` with `bootstrap.recovery` referencing an `externalCluster`
   that points at the same `barmanObjectStore` destination + Workload-Identity.
2. For PITR, set `recoveryTarget.targetTime`; omit for latest.
3. The recovery KSA needs a `roles/iam.workloadIdentityUser` binding on the GSA
   for `…svc.id.goog[<ns>/<recovery-ksa>]`, and the namespace needs egress to GCS.
4. Validate (table counts / app smoke test), then cut traffic over.

## Recommendations / follow-ups
- **Quarterly** re-run the restore drill (or automate it as a CronJob) so RTO/RPO
  stay verified as the DB grows.
- Add CNPG backup-failure alerting (`pg_stat_archiver.failed_count` increasing,
  or `lastSuccessfulBackup` age) — the April archive failures went unnoticed.
- Consider a monthly **full CNPG recovery-cluster** drill (not just standalone) to
  validate the end-to-end DR path including provisioning time.
