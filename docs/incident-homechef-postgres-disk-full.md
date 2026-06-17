# BUG / Incident — homechef-postgres CNPG cluster: "Not enough disk space" + wedged replicas

> Single source of truth for the HomeChef PostgreSQL disk/HA incident.
> Read this before touching `charts/apps/homechef-postgres/`.

## Classification

| Field | Value |
|-------|-------|
| **ID** | INC-2026-06-17-homechef-pg-disk |
| **Title** | `homechef-postgres` stuck in `Not enough disk space`; HA broken (1/3 ready) |
| **Severity** | **SEV-2 / High** — production HA fully degraded (no replica, no failover). *Not* a full outage: the primary (`homechef-postgres-7`) is healthy and serving via the pooler. Escalates to **SEV-1** if the primary's data or WAL volume fills. |
| **Type** | Reliability · Database · Storage (WAL retention) · Observability gap |
| **Component** | CNPG cluster `homechef-postgres` (namespace `homechef`) |
| **Affected since** | Cluster `Ready=False` since **2026-05-12**; root trigger originates from the April WAL-volume-full event |
| **Detected** | 2026-06-17 (manual) — *not* caught by alerting (see Observability gap) |
| **Status** | **Resolved** — HA restored (3/3 streaming, quorum sync) · prevention + detection + self-healing in place |
| **Data loss** | **None.** `homechef_db` = 13 MB, intact (4 users, early-stage data). Primary is authoritative. |

## Symptoms

- `kubectl get cluster homechef-postgres -n homechef` → `STATUS: Not enough disk space`, `READY 1/3`.
- `homechef-postgres-10` — `CrashLoopBackOff`, 560+ restarts over ~47h.
- `homechef-postgres-8` — `Running 0/1`, readiness probe `500` for ~9h (stuck in startup recovery).
- `homechef-postgres-7` — primary, healthy, serving traffic.

## What actually filled the disk (root cause)

This is **two linked failures**, not one.

### 1. Original trigger — WAL volume filled on the primary (April 2026)

The cluster originally ran with `walStorageSize: 10Gi` and `max_slot_wal_keep_size: 10GB`.
CNPG keeps a **per-replica HA replication slot** on the primary. When a replica
went down, its slot pinned WAL on the primary, and because the slot ceiling
(10 GB) equalled the entire WAL volume (10 Gi), the retained WAL **filled the
WAL volume**. PostgreSQL cannot write WAL on a full volume → the primary
crashed / failed over.

Fixed 2026-04-27 (commit `1db25375`): `walStorageSize 10Gi→30Gi`,
`max_slot_wal_keep_size 10GB→8GB` (WAL volume now sized **3× the slot ceiling**,
so a single stuck slot can never fill it). This part of the fix is correct and
verified live (`max_slot_wal_keep_size = 8192 MB`; primary WAL = ~580 MB / 30 Gi).

### 2. Residual deadlock — what kept it broken for 5 weeks

The April incident left the cluster thrashing (current `timeLineID = 59` ⇒ ~58
failovers/recoveries). During that churn:

1. The two replicas (`-8`, `-10`) fell far behind. The primary, correctly
   honouring `max_slot_wal_keep_size = 8GB`, **recycled the WAL** their slots
   needed → both slots became `lost` (live: `_cnpg_homechef_postgres_8` and
   `_cnpg_homechef_postgres_10` are `active=f`, `safe_wal_size = -85 GB`).
2. A `lost` slot means the replica **can never catch up by streaming** — it
   needs a full re-bootstrap (`pg_basebackup`) or `pg_rewind` + WAL restore.
   `pg_stat_replication` on the primary shows **0 rows** → no replica streaming.
3. `homechef-postgres-8` is stuck *permanently* in `the database system is
   starting up` (recovery never completes — the WAL it wants is gone).
4. `homechef-postgres-10`'s **own WAL volume was left full** from the April
   event. CNPG's instance-manager runs a pre-start guard
   (`Checking for free disk space for WALs before starting PostgreSQL` →
   `Detected low-disk space condition, avoid starting the instance`). It refuses
   to start Postgres → Postgres never runs → WAL is never recycled → the volume
   stays full. **Self-sustaining deadlock.**
5. A single instance reporting low disk pins the **whole cluster** into the
   `Not enough disk space` phase, so CNPG never finishes reconciling/rebuilding
   the other replica. Stuck for 5 weeks.

**One-line root cause:** replication-slot WAL retention on an undersized WAL
volume filled the disk; the resulting failover storm left both replicas with
`lost` slots and one replica with a full WAL volume that CNPG's pre-start guard
can't recover from, deadlocking the cluster.

## Observability gap (why it went unnoticed for 5 weeks)

The existing PrometheusRule had **no direct disk-space alert**, and its
instance-down alert was ineffective for this failure mode:

- `CNPGInstanceDown: cnpg_collector_up == 0` — a crashlooping/absent pod emits
  **no `cnpg_collector_up` series at all**, so `== 0` never matches. The down
  instance was invisible to alerting.
- `CNPGWALAccumulation` (WAL > 1 GB) is only a proxy and didn't fire because the
  primary's WAL was being recycled fine — the problem was the *replicas*.

This is fixed below.

## Permanent fix

### A. Preventive — alerting (committed to Git, deployed via ArgoCD)

Added to `charts/apps/homechef-postgres/templates/prometheusrule.yaml`:

- **`CNPGVolumeSpaceCritical`** (`< 10%` free, 5m) / **`CNPGVolumeSpaceLow`**
  (`< 25%` free, 15m) — per-PVC, fires on data *or* `-wal` volume. The direct
  guard the original incident lacked.
- **`CNPGClusterInstancesNotReady`** — `count(cnpg_collector_up == 1) < instances`
  for 15m. Uses a *count* so absent/crashlooping series are detected. This would
  have fired within 15 minutes on 2026-05-12.

> Roll the same three rules into every other `charts/apps/*-postgres/` chart —
> they all share this template and the same blind spots.

### B. Structural safeguards already in place (verified live)

- `walStorageSize: 30Gi` = 3× `max_slot_wal_keep_size: 8GB` — a stuck slot
  cannot fill the WAL volume.
- `resizeInUseVolumes` / `standard-rwo-retain` allow online PVC expansion.
- Continuous archiving + twice-daily backups to GCS (verified succeeding).

### D. Auto-remediation — self-healing (committed to Git, deployed via ArgoCD)

So this never needs a human running `cnpg destroy` again, a self-healing
CronJob (`charts/apps/homechef-postgres/templates/autoheal-cronjob.yaml`,
`autoheal.enabled: true`) runs every 10 minutes and:

1. Reads cluster status (`currentPrimary`, `readyInstances`, `instances`, phase).
2. Exits immediately if the cluster is already healthy (`ready == instances`).
3. **Refuses to act unless the primary exists and is `Ready`** (a clean rebuild
   source must exist — guarantees no data loss).
4. Finds any **non-primary** instance pod (`^<cluster>-<serial>$`) that has been
   not-`Ready` for longer than `stuckMinutes` (default 15m — longer than a normal
   rolling restart so upgrades aren't disrupted).
5. Deletes that instance's pod + data/WAL PVCs; the CNPG operator then
   re-bootstraps a fresh replica from the primary.

This is the automated form of the manual recovery below, and it heals both
observed wedge modes (full-WAL pre-start guard, and `lost`-slot stuck-startup)
because the rebuild always starts from a clean volume. RBAC is namespace-scoped
(`get cluster`; `get/list/delete pods` + `persistentvolumeclaims`). The primary
is never a candidate. `concurrencyPolicy: Forbid` prevents overlapping runs.

> The same template + `autoheal` values block should be added to every other
> `charts/apps/*-postgres/` chart for fleet-wide self-healing.

### C. Operational recovery (run once to clear the current deadlock) — DONE 2026-06-17

> This was executed on 2026-06-17 to clear the existing deadlock: both wedged
> replicas (`-8`, `-10`) were rebuilt via `kubectl cnpg destroy`, the operator
> re-bootstrapped fresh replicas (`-11`, `-12`) from the primary in ~25s each,
> and the cluster returned to `3/3` healthy with quorum-sync streaming
> replication. Kept here as the manual runbook; going forward section D
> automates it.

Replicas hold no unique data — the primary is authoritative — so destroying and
rebuilding the two broken replicas is safe (no data loss). Preferred path uses
the CNPG kubectl plugin:

```bash
export KUBECONFIG=~/.kube/gke-prod

# 0. Confirm primary is healthy and authoritative
kubectl get cluster homechef-postgres -n homechef
kubectl exec -n homechef homechef-postgres-7 -c postgres -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"   # expect: f

# 1. (Preferred) install the cnpg plugin, then destroy the two bad instances.
#    `destroy` removes the pod AND its PVCs and lets the operator rebuild.
kubectl krew install cnpg   # or download the cnpg plugin binary
kubectl cnpg destroy homechef-postgres 10 -n homechef
kubectl cnpg destroy homechef-postgres 8  -n homechef

#    Fallback if the plugin is unavailable (delete pod, then its PVCs):
# kubectl delete pod homechef-postgres-10 -n homechef --grace-period=1
# kubectl delete pvc homechef-postgres-10 homechef-postgres-10-wal -n homechef
# kubectl delete pod homechef-postgres-8  -n homechef --grace-period=1
# kubectl delete pvc homechef-postgres-8  homechef-postgres-8-wal  -n homechef

# 2. Drop the zombie slots ONLY if CNPG hasn't already (it normally auto-cleans
#    slots for instances that no longer exist):
kubectl exec -n homechef homechef-postgres-7 -c postgres -- psql -U postgres -c \
  "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots
   WHERE active='f' AND slot_name LIKE '_cnpg_%';"

# 3. Watch CNPG rebuild fresh replicas from the primary (homechef_db is ~13 MB,
#    so basebackup is near-instant). Expect READY 3/3, STATUS healthy.
kubectl get cluster homechef-postgres -n homechef -w
kubectl get pods -n homechef -l cnpg.io/cluster=homechef-postgres

# 4. Storage class is `Retain` — the old PVs from -8/-10 (+ -wal) will be left
#    in `Released`. Reclaim the disk/cost once 3/3 is healthy:
kubectl get pv | grep homechef-postgres   # delete the `Released` ones
```

> Per repo policy, cluster mutations go through ArgoCD — but instance pods/PVCs
> are created and owned by the **CNPG operator**, not ArgoCD (ArgoCD only owns
> the `Cluster` CR). Rebuilding a replica does not drift from Git; it is the
> supported CNPG operational remediation.

## Verification after recovery

- `kubectl get cluster homechef-postgres -n homechef` → `READY 3/3`, healthy.
- `SELECT * FROM pg_stat_replication;` on the primary → 2 streaming replicas,
  `sync_state` populated.
- `SELECT slot_name, active, wal_status FROM pg_replication_slots;` → slots
  `active=t`, `wal_status=reserved`.
- New alerts present: `kubectl get prometheusrule homechef-postgres-alerts -n homechef -o yaml`.

## Follow-ups

- [x] Run the operational recovery (section C) — done 2026-06-17, cluster 3/3.
- [x] Add prevention (WAL sizing), detection (3 alerts), self-healing (autoheal CronJob).
- [ ] Propagate the three alerts **and** the autoheal CronJob to every other
      `*-postgres` chart (ideally via the shared `common` chart so all clusters
      inherit prevention + detection + self-healing automatically).
- [ ] Reclaim the 4 `Released` PVs from the destroyed replicas (`Retain` SC
      leaves the backing GCE PDs — delete the PV objects **and** the PDs):
      `pvc-a0eb4e6d…` (pg-8), `pvc-4232cb31…` (pg-8-wal),
      `pvc-76124eb9…` (pg-10), `pvc-9c8767e6…` (pg-10-wal) — ~260 Gi total.
- [ ] Consider upgrading CNPG past 1.24.1 — newer operators handle the
      low-disk pre-start guard more gracefully.
- [ ] Consider whether `minSyncReplicas: 1` is desired — synchronous commit
      blocks writes when no replica is available (CNPG self-heals by ignoring
      it, but it adds fragility under churn).
