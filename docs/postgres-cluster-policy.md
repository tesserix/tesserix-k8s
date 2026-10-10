# PostgreSQL cluster policy — use `global` or `infra`, do not create a new one

## The rule

A service that needs PostgreSQL gets a **database on an existing cluster**. It
does not get a cluster.

| Your service is… | Use | Host |
|---|---|---|
| A platform or product service — anything user-facing, tenant-facing, or business logic | **`global-postgres`** | `global-postgres-rw.global.svc.cluster.local` |
| Temporal, or SRE / observability tooling | **`infra-postgres`** | `infra-postgres-rw.infra.svc.cluster.local` |

If you believe you need a third cluster, read "When a new cluster is
justified" at the bottom first. The answer is almost always no.

## Why this rule exists

The estate reached **ten CNPG clusters holding ~1.1GB of data between them,
against 928Gi of provisioned volume** — under 0.2% utilisation. Most are
single-instance, which on Spot-only node pools means the database disappears
with the node. Three have no backup configured at all.

The per-product cluster habit came from this repo's own guidance, which used to
read "chart pattern `charts/apps/{product}-postgres/`, per-product
`values.yaml`". That is now legacy. The clusters listed under "Existing
clusters" below are grandfathered, not a template.

Consolidating is also *safer*, not just cheaper: one cluster with a primary and
a synchronous replica survives a node loss as a leader election. Eight
single-instance clusters each survive it as an outage.

## Which cluster, and why there are two

**`global-postgres`** is the shared platform cluster. It already hosts thirteen
databases: `global_db`, `keycloak_customer`, `keycloak_internal`, `tenants_db`,
`notifications_db`, `subscriptions_db`, `documents_db`, `verifications_db`,
`onboarding_content_db`, `custom_domains_db`, `location_db`, `tenant_router_db`,
`kora_db`. New platform and product databases belong here.

**`infra-postgres`** exists for exactly one reason: **blast radius**. Temporal
runs ~36–77 connections and dominates the write rate, measured against 11
connections across all twelve of `global`'s databases combined. `global` serves
both Keycloak stores, so a Temporal write storm there degrades authentication
for every product. Keeping that load off the auth cluster is the whole
justification — not consolidation, and not "infra things go in the infra
namespace".

So: **do not put a general service on `infra-postgres` because the name sounds
right.** The test is whether it is Temporal or SRE tooling. If not, it goes to
`global`.

## Adding a database

Two steps, and the first one does **not** do what its name suggests.

### 1. Declare it (for reproducibility)

Add the `CREATE DATABASE` line to the cluster's `bootstrap.postInitSQL` in
`charts/apps/{global,infra}-postgres/values.yaml`.

> **`postInitSQL` runs ONCE, at cluster creation.** Adding a line does not
> create the database on a running cluster. It only makes a rebuild reproduce
> it. If you stop here, the database exists in git and nowhere else.

### 2. Actually create it

Either provision it directly against the running cluster, or add a schema file
under `charts/apps/db-schema-bootstrap/schemas/<project>/<database>/` — the
bootstrap CronJob creates missing databases and applies the schema idempotently
every 30 minutes. `global-postgres` is already a configured target of that job.

Keep both in sync. A database created only in step 2 vanishes on a rebuild; one
declared only in step 1 never exists at all.

> **The bootstrap CronJob needs its target role to have CREATEDB.** It connects
> as the cluster's owner role, and CNPG creates that role without CREATEDB, so
> `CREATE DATABASE` fails and the run reports an error nobody reads — the
> database simply never appears. Grant it in `managedRoles` (`createdb: true`),
> which reconciles on a running cluster, not in `postInitSQL`.

## Two traps that cost real debugging time

**Poolers are transaction-mode PgBouncer.** They do not carry prepared
statements across a transaction boundary. An application whose driver prepares
and reuses statements (Temporal's `postgres12` driver, for one) must connect to
the `-rw` service directly. Symptoms are sporadic "prepared statement does not
exist" errors under load rather than a clean failure at startup. `infra-postgres`
runs with poolers disabled for this reason.

**Cross-namespace access needs a NetworkPolicy.** Once any egress policy selects
a pod, its namespace denies by default. A service reaching a database in another
namespace needs an additive policy naming that namespace — see
`manifests/homechef-istio/networkpolicy-infra-egress.yaml`. Without it the
failure looks like the database being down, not like a policy drop, which has
now cost this repo two separate misdiagnoses (homechef→observability for traces,
homechef→infra for Temporal).

Also remember `cnpg-system` must be in the **ingress** policy of any namespace
hosting a cluster, or the operator cannot reach pods on port 8000 and replicas
are never created.

## Existing clusters (grandfathered — not a template)

| Cluster | Namespace | Instances | Storage | Backup |
|---|---|---|---|---|
| `global-postgres` | `global` | 1 | 20Gi + 5Gi WAL | yes |
| `infra-postgres` | `infra` | 2 (primary + sync replica) | 20Gi + 8Gi WAL | yes |
| `homechef-postgres` | `homechef` | 2 (primary + standby) | 100Gi + 30Gi WAL | yes |
| `mark8ly-postgres` | `mark8ly` | 1 | 200Gi | yes |
| `tesserix-postgres` | `tesserix` | 1 | 15Gi | yes |
| `devai-postgres` | `devai` | 1 | 10Gi | yes |
| `support-platform-postgres` | `support-platform` | 1 | 20Gi | **no** |
| `agentregistry-postgres` | `agentregistry-system` | 1 | 8Gi | **no** |
| `postiz-postgres` | `postiz` | 1 | 10Gi | **no** |
| `stockpilot-postgres` | `stockpilot` | hibernated, volumes held as snapshots | none (snapshots only) | **no** — see below |
| `planning-poker-postgres` | `planning-poker` | 1 | 10Gi + 2Gi | **no** — needs the WI binding first |
| `zitadel-postgres` | `zitadel` | 3 (primary + 2 replicas) | 20Gi + 8Gi | **no** — needs the WI binding first |

Known gaps worth fixing when touching any of these: three clusters run with no
backup at all, and `global-postgres` is single-instance while hosting both
Keycloak stores — its own chart notes it should return to multiple instances
once the WAL volume is ≥16Gi.

### Hibernated clusters have no backups

CNPG refuses to back up a hibernated cluster, so its scheduled backups fail
daily, and the bucket lifecycle deletes every Postgres prefix after 10 days.
Ten days after hibernation the object store holds nothing. Snapshot the disks
before you rely on hibernation as storage.

`stockpilot-postgres` was hibernated in June 2026; its last good backup was
2026-06-12 and had expired by October. On 2026-10-09 both volumes were
snapshotted (`stockpilot-pg-data-final-20261009`, `stockpilot-pg-wal-final-20261009`,
`asia-south1`), a restore was mounted and checked (PostgreSQL 16, 5 databases,
about 150 MB), and the 100Gi and 20Gi disks were removed. The Cluster resource
stays in Git, hibernated.

To bring it back, before removing the `cnpg.io/hibernation` annotation:

1. Create `pd-balanced` disks in `asia-south1-b` from the two snapshots.
2. Recreate PVs pointing at them, then the PVCs `stockpilot-postgres-1` and
   `stockpilot-postgres-1-wal` in `stockpilot`, with the CNPG metadata they
   had: `cnpg.io/cluster: stockpilot-postgres`,
   `cnpg.io/instanceName: stockpilot-postgres-1`, `cnpg.io/instanceRole: primary`,
   `cnpg.io/nodeSerial: "1"`, `cnpg.io/pvcStatus: ready`, and
   `cnpg.io/pvcRole: PG_DATA` or `PG_WAL`. Storage class `standard-rwo-retain`.
3. Remove the hibernation annotation and let CNPG start the instance.
4. Run a backup at once; the old WAL archive in the bucket has expired.

## When a new cluster is justified

Only when a workload would harm its neighbours on a shared cluster, and you can
show it. The `infra-postgres` split was made on measured connection counts and
write rates against a cluster serving authentication — not on a hunch that the
workload "felt heavy".

Otherwise the bar is: different compliance/residency boundary, or an extension
or major version the shared cluster cannot run.

"It is a new product" is not a reason.

`zitadel-postgres` was granted on the first test: it is event-sourced, so every
authentication is a write, and `global` already carries both Keycloak stores —
putting the replacement on the same cluster as the thing it replaces makes the
cutover a single point of failure. See [`zitadel.md`](zitadel.md).

## Related

- [`docs/cnpg-migration-guide.md`](cnpg-migration-guide.md) — creating, modifying, debugging, migrating
- [`docs/cnpg-backup-restore.md`](cnpg-backup-restore.md) — backup and restore procedures
