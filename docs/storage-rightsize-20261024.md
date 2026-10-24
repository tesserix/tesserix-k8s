# Application storage reduction, 2026-10-24

Approved targets: OpenPanel ClickHouse 120Gi; the two Mark8ly PostgreSQL data
volumes, two parked FE3DR PostgreSQL data volumes and blog MongoDB volume 60Gi
each. Smaller WAL and application volumes are unchanged. Expected reduction:
540Gi, approximately AUD86/month at observed rates; CUD payments are unaffected.

GCP persistent disks cannot shrink. The migration therefore uses a new PVC for
each target, an offline filesystem copy and a controlled binding cutover.
FE3DR remains parked. Mark8ly database, blog database and OpenPanel have a
temporary maintenance outage; their original replica counts are restored after
verification. Retained source disks and snapshots provide rollback.

Phase 1 keeps original storage sizes and PVCs unchanged, hibernates Mark8ly using
CNPG's native annotation, stops blog MongoDB and OpenPanel writers, and creates
the six target PVCs and one-shot copy Jobs through Argo CD. The Jobs verify the
source PVC UID, wait until no other non-terminal pod references it, mount the
source read-only, refuse non-empty destinations and require 15% free headroom.
GNU cp preserves ownership, sparse files, symlinks and hardlinks; SHA-256 verifies
every regular file. Root is needed only to preserve existing database ownership;
the container has no admin capabilities, a read-only root filesystem and
namespace-scoped read-only Kubernetes access. No database content is logged.

Before phase 2, capture stopped-source GCP disk snapshots and resource metadata,
and require all six copy Jobs to succeed. Retain old PVs before deleting any PVC.
Rebind the verified replacement disks under the existing claim names, preserving
database ownership/labels and WAL volumes. Update desired storage sizes through
GitOps so controllers cannot expand the new disks again. Do not resume a database
until both the requested and actual capacity match the approved target.

Verify database startup, existing database/table counts and application health
before retiring original disks. If verification fails, keep writers stopped and
rebind the retained original disks; never mix an old data directory with a WAL
volume that has advanced after resumption. A post-resumption rollback must use a
consistent fresh backup/restore, not a stale filesystem swap.

The copy Jobs do not delete sources or perform the binding cutover. Their success
is evidence of a verified copy, not evidence that a migration is complete.

Copy retry: original Jobs are suspended before separate v2 Jobs run. Retries
validate target PVC identity, wait for exclusive source/target access, hash-check
existing copies before metadata repair, and include FSETID to preserve setgid
bits. Kubernetes API access uses the injected service IP. Root-directory ownership
and modes and every entry's file type are included in verification. No source PVC
or disk is removed during this phase. OpenPanel remains targeted at 120Gi.

The OpenPanel copy was interrupted by suspension and requires a full recopy into
its identity-checked temporary target. Only its v3 Job explicitly permits this.
The PostgreSQL operator rejects storage decreases. Both hibernated Cluster
reconciliation loops are temporarily disabled before their controlled metadata
recreation; all PVCs, secrets and database data must be orphan-preserved, and
current-primary/status metadata restored before reconciliation resumes.

Cutover phase: all six zonal source snapshots reached READY (names
`rightsize-<original-claim>-20261024`, project `tesseracthub-480811`). Local
metadata, snapshots and copy logs are in `/tmp/fe3dr-park-20261024`. The five
60Gi copies passed SHA-256 verification. OpenPanel stays in copy mode until its
separate completion evidence is recorded.

For PostgreSQL, a wave -1 Job first stores the frozen Cluster definition/status
in `rightsize-cluster-recovery` in its own namespace, deletes only that Cluster
with Orphan propagation, recreates it at 60Gi with reconciliation disabled,
restores the recorded primary/status and reattaches the original data/WAL PVC
owner references. No child resources or secret values are deleted/read. Wave 0
Jobs retain both physical disks, remove only identity-checked old/temporary
claims, and prebind the copied disk under the original claim name. The original
physical disks remain retained until post-startup verification. Temporary access
is scoped to named PVs, PVCs, copy Jobs and Clusters; create permissions cannot be
resource-name restricted by Kubernetes RBAC.

Blog MongoDB's stopped StatefulSet is recreated with explicit PVC Retain policies
to change its immutable claim template. Remove the temporary Force/Replace
annotation before resuming it. Resume Mark8ly only after both replacements are
Bound at 60Gi and its original primary is preserved. FE3DR remains hibernated.

The five 60Gi claims are now Bound to the verified copied disks. Both PostgreSQL
Clusters retain their original primary identities. Mark8ly and blog MongoDB can
resume; FE3DR remains hibernated. Reconciliation freezes and the temporary blog
Force/Replace annotation are removed. OpenPanel needs a 2Gi-memory verification
retry after its large file inventory exhausted the previous 512Mi limit.
