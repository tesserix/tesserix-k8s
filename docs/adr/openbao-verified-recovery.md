# Verified OpenBao backups

The current compressed Raft snapshot is about 220 KiB (September 2026). Two runs
per day and three retained snapshots require under 1 MiB today; budget 1 GiB per
snapshot and 2 GiB ephemeral job storage for growth. This is a batch workload:
no permanent operator or database is needed. Recovery-point objective is 12 hours;
an isolated restore must finish within 15 minutes (measured during acceptance).
A stale-backup alert fires after 14 hours. Production recovery time includes
operator approval and replacement-cluster provisioning, and is not an automatic
failover SLO.

Use a dedicated private STANDARD GCS bucket with a dedicated CMEK, no object
versioning or soft deletion. Count-based retention is implemented by the job;
GCS age rules cannot keep the newest three distinct objects. The existing shared
bucket has a 30-day minimum retention policy; historical recovery artifacts there
keep their existing lifecycle instead of weakening protection for other products.

Backup jobs use projected Kubernetes identity and Workload Identity. The production
OpenBao policy permits only Raft snapshot reads and a dedicated verification marker.
The isolated restore process listens on loopback, has no retry_join or Kubernetes
service registration, and uses fresh Kubernetes auth after restoring. It checks
the marker version and checksum using a read-only verification policy. No product
secret values or long-lived root tokens are exported for verification.

Upload with generation preconditions, download and compare SHA-256 and CMEK
metadata, perform a real Raft restore and KMS auto-unseal, then publish a metadata
catalog using compare-and-swap. Only catalogued, restore-verified snapshots count
as backups. Prune superseded object generations only after catalog publication.
A failed capture, upload, restore or catalog update keeps earlier recovery points.
Concurrent publishers retry the catalog CAS; object IDs are immutable and unique.

The console integration exposes catalog metadata and fixed backup/isolated-test
operations through its authenticated backend. It does not return snapshot bytes,
KMS credentials, marker values or OpenBao tokens. A restore test never overwrites
production. Production recovery is a separate, explicitly approved operation
against a named target with a pre-restore snapshot and writes quiesced.

GCS/KMS failure causes a failed run and alerts, with existing snapshots retained.
An interrupted upload is never catalogued; a completed but unpublished candidate
is removed when safely identifiable. The job deadline and ephemeral storage bound
resource use. At the current data size, object storage and request charges are
negligible; restore-job CPU/memory and KMS calls are the dominant incremental cost.

Rollback restores the previous chart schedule/bucket configuration; the new bucket
and KMS keys have Terraform prevent_destroy protection. Neither rollback nor a
failed drill changes live Raft data. Migration acceptance requires four successful
backups, exactly three retained catalogued snapshots, an independent restore of a
retained snapshot, and a corrupted-snapshot rejection without production mutation.
