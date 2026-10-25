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
a canary first, then small batches with independent recovery and verification
receipts for each product. A chart value named `storageMigrationPhase` controls CNPG:
`quiesce` requests data-preserving hibernation with the operator active.
After all database pods terminate, `copy` additionally disables reconciliation
so the controller cannot race PVC replacement. Never use a chart's `hibernate`
value blindly: some legacy charts remove the Cluster instead of hibernating it.

The migration chart's separate `economy-values.yaml` records exact source PVC
UIDs, PVs, physical disk handles, same-sized target claims, and cutover evidence.
Import READY cold GCP snapshots as retained VolumeSnapshotContent and
VolumeSnapshot resources, then restore same-sized standard target PVCs from
them. Record the observed target UIDs before enabling verification. Non-root
verification jobs mount both volumes read-only, fail if any other active pod
references either volume, and compare file data and metadata without repairs
or writing a marker. This satisfies restricted Pod Security without weakening
the namespace policy. Workload dry runs alone do not prove Pod admission;
validate the actual Pod template as well.

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

## Original disk reclamation

For active products, require healthy restart, matching application schema and
fresh WAL archival before capturing an exact cloud deletion receipt for each
migration original. Previously parked products retain their parked state: record
`parkedVerified` only after offline content/metadata verification, exact standard
target bindings and no active pod references. Runtime startup is not claimed for
these parked products. Immediately before
GCE deletion, require the captured disk ID, zero attachments, no current Bound PV
claim, a READY recovery snapshot with matching sourceDiskId, and a verified
standard replacement disk. Keep the cloud snapshot and recovery metadata.
Do not apply this procedure to unrelated historical retained generations.

Only then set `resumeVerified` (or `parkedVerified` for a previously parked
product), `sourceDiskDeletedId` and `sourcePVUID` in the
migration ledger and use phase `cleanup`. The restricted cleanup job verifies
the current replacement UID/PV binding and deletes only the exact Released,
Retain original PV, with UID/resourceVersion preconditions. It may remove a
recorded prior empty target only if its UID matches, it is Pending, has no
volume or snapshot source, and no active pod references it. Return to `complete`
and prune temporary jobs and permissions after successful cleanup.

## Non PostgreSQL writer quiescence

For Mark8ly MongoDB, Support Platform MongoDB and GrowthBook MongoDB,
`storageMigrationPhase` holds the database controller at zero replicas without
removing its claims. StatefulSet claims explicitly retain data when scaled or
deleted. Leave the original storage class unchanged during the initial pause.

Disable the owning Application's automated sync in Git before claim replacement,
then selectively sync the named database controller to zero. This maintenance
sync deliberately does not run application seeding hooks against a stopped
store. Verify the live automation flag, a terminal sync operation, no active
pod references and detached source disks before cold snapshots. This prevents
self-heal from recreating a static PVC while the binding job replaces it.

StatefulSet volumeClaimTemplate storage classes are immutable. Reconcile a
zero-replica retained controller to its new class only after exact standard
bindings and offline verification are established. Restore the original sync
policy and clear the migration phase for the full resume sync and its normal
hooks. Verify writable database state, the application and recovery receipts
before source reclamation. Previously parked HomeChef remains parked.

Product NATS uses the same paused controller and Retain policy. Only the
explicit `reconcile` phase enables Argo force replacement of its stopped
StatefulSet. Capture the old controller, verify every replacement claim has no
controller owner reference, then verify the new controller UID, zero replicas,
standard claim template and unchanged claim bindings before clearing the phase.
Compare JetStream stream/consumer configuration and health after restart.

Preserve each Application's Helm input format. Argo `valuesObject` takes
precedence over inline `values`; put a migration override inside inline values
when that is the application's existing configuration. Verify the complete
effective overlay, not only the migration setting. Static claims with existing
explicit bindings must retain their verified `volumeName`; normal reconciliation
must not clear immutable fields.

MongoDB database files require SHA-256 verification. The three active MongoDB
stores contain operator-created `.mongodb/mongosh/*_log` diagnostics unreadable
by the database UID. Their explicit opt-in exception compares inventory, type,
ownership, mode, size and modification timestamp and logs every such path.
It does not claim content hashes for those diagnostic logs or relax verification
for database files. Both volume mounts remain read-only and cold recovery
snapshots are retained.

For parked HomeChef Percona MongoDB, keep the CR paused and its operator at zero.
Render the pinned external chart and server-dry-run its CR; the only spec change
is the retained standard storage class. After all three original claim names
bind their verified targets, phase `retire-homechef-mongo` removes only the exact
old zero-replica StatefulSet. Its API-only job checks CR/operator/controller UIDs,
Retain policy, no active operator or volume users, and each current PVC/PV/disk
binding without PVC controller owner references. Deletion uses UID and resource
version preconditions. The paused CR is the permanent desired state; a future
operator resume recreates the StatefulSet from its new claim-template class.
Do not start HomeChef to claim runtime verification: acceptance remains offline
and explicitly parked. Retain private recovery metadata outside temporary
storage before deleting claim objects or source disks.

OpenPanel resume requires stores and clients to be available before its PreSync
migration and project-init hooks. With automation disabled, selectively warm up
the restored Deployments, then run a fresh full sync with normal hooks. Wait for
the previous operation to terminate and its spec operation to clear; reset the
completed operationState when submitting an explicitly empty resource filter
so a previous selective filter cannot survive merge patching. Restore automation
only after acceptance. Project-init labels exported public client IDs using
`kubectl label --local` before apply; `create secret generic --labels` is not
supported by the pinned kubectl.

After all source disks are confirmed absent and source PV cleanup jobs succeed,
set economy phase to complete with an empty volume list and sync with pruning.
Retain recovery snapshots and private recovery metadata independently.
