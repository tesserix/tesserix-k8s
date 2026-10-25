# Product database migration to standard persistent disks

The owner requested standard persistent disks for product databases, including
Helivanta, while workloads are preproduction. Existing SSD disks are acceptable;
moving balanced disks to SSD would increase cost. The target class is
`economy-rwo-retain` (`pd-standard`), not `standard-rwo-retain` (`pd-balanced`).

## Scope and acceptance

Product PostgreSQL charts: DevAI, Dwellm8 and its Temporal database, Helivanta,
HomeChef, Kora, Mark8ly, Planning Poker, Postiz, Roamie, Support Platform and
Tesserix. MongoDB, OpenPanel PostgreSQL/ClickHouse/Redis and product NATS volumes
are included in the inventory and subsequent batches. Shared platform stores
(global, infra, identity, registry, OpenBao) remain a separate decision.

Keep existing capacity, replication, encryption, database identity, credentials,
backup configuration and tenant boundaries. Change storage type only.
The user accepts lower performance and migration downtime before production;
no numerical production latency SLO or workload growth forecast was supplied.
The canary is Planning Poker: four volumes totalling 24 GiB, two healthy
PostgreSQL instances, and 18 application tables before quiescing. Do not infer
that a small filesystem snapshot proves peak IOPS or future traffic capacity.

Successful cutover requires matching file inventories, exact ownership/modes and
SHA-256 file contents on the offline copy; Bound replacement PVCs of the intended
class/physical type; two Ready PostgreSQL instances with a writable primary and
streaming standby; the application schema and service endpoints preserved.
Measure restart and application latency before accepting each product batch.

## Durable workflow

Reuse the existing storage-rightsize copy and binding implementations. Migrate
one product at a time. A chart value named `storageMigrationPhase` controls CNPG:
`quiesce` requests data-preserving hibernation with the operator active.
After all database pods terminate, `copy` additionally disables reconciliation
so the controller cannot race PVC replacement. Never use a chart's `hibernate`
value blindly: some legacy charts remove the Cluster instead of hibernating it.

The migration chart's separate `economy-values.yaml` records exact source PVC
UIDs, PVs, physical disk handles, same-sized target claims, and cutover evidence.
Prepare retained standard targets first. Record their observed UIDs before
enabling copy. Copy jobs mount the source read-only and fail if any other active
pod references either volume. They verify data and file metadata before success.

Capture the quiescent source disks as READY GCP snapshots with recorded source
disk identities, and keep original PVC/PV configuration in a private evidence
directory. Never commit database contents, credentials, raw secrets or state.

After successful copy, record target PV/disk identities and successful job
evidence. GitOps binding jobs retain both PVs, remove temporary completed copy
pods, replace the original claim with a claim bound to the verified standard
target, and preserve the CNPG owner and instance metadata. The original disk is
retained. No Cluster recreation or credential replacement is required when size
and database identity are unchanged.

Remove the temporary CNPG pause only after every claim for that product is
Bound to its intended replacement. Preserve any pre-existing hibernation, such
as HomeChef. Verify physical disk type, healthy replication, SQL metadata,
application health and backups. Mark each batch complete and remove temporary
jobs and permissions. Original disks remain billable until separately verified
and reclaimed; temporary targets and snapshots can briefly increase costs.

## Recovery

Before writers resume, rebind to the retained original volumes if verification
fails. Restore snapshots only if the original disks are unavailable. After
writers resume, the original copy is stale: stop writes and preserve/copy the
newest data before rollback. Never silently discard writes made after cutover.
Record capture paths, snapshot names, timestamps, original/target UIDs and the
resume decision for every product.

Changing chart defaults alone does not migrate existing PVCs. Completion is
proved by the actual GCE disk type for every scoped volume, not a Helm value or
a successful ArgoCD sync. The older general PVC runbook's blanket exclusion of
database migrations is superseded only for this explicitly authorized
preproduction storage change.
