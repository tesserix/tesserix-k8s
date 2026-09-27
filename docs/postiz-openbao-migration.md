# Postiz OpenBao migration

Tracked in [#1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

Seventeen production sources contain enabled payloads; sixteen other source
records have no enabled versions. The reviewed catalog covers the seventeen
usable credentials. The application uses sixteen bindings in two Kubernetes
Secrets; the remaining API key is preserved separately without granting ESO
access to it. Shared registry credentials remain in GCP.

Destinations are `postiz/app/postiz-<secret>`. A namespaced ESO identity receives
read-only access to exactly the sixteen active dependencies. The staging role
is bound to `openbao/postiz-migration-writer`, lasts fifteen minutes and grants
create/read only on reviewed paths. CAS=0, pinned versions and readback prevent
accidental overwrites. Remove the temporary identity after staging.

Baseline: Deployment ready 1/1; UI and registration configuration return 200;
unauthenticated user and public API requests return 401. Private evidence and
source metadata are under `/tmp/remaining-openbao-evidence/postiz/` (0700).
The encrypted source archive must pass remote download/decrypt equality before
source deletion; preserve metadata/IAM and enabled historical versions.

Acceptance requires fresh ESO reconciliation with unchanged target hashes,
namespace scope denial, functional database/API/storage checks, and a verified
OpenBao backup with isolated restore. Empty source records require separate
metadata review and capture. Do not claim a social OAuth flow was exercised
without provider interaction. Before deletion rollback can restore GCP refs;
after deletion recovery requires the KMS-encrypted archive and key.

The credentials are protected against cross-namespace reads by Kubernetes auth
and exact-path ACLs. Logs and repository files contain no payloads. No new
persistent workloads are needed; the additional KV records have negligible cost.

## Reviewed cutover

All 33 source records are captured in the verified recovery archive:
`gs://tesseract-prod-backups-in/openbao/postiz-migration/20260927T140208Z/gcp-sources.json.gz.kms`.
Sixteen have no versions at all; they are empty shells, not missing payloads.
The other seventeen sources include all enabled historical versions, metadata
and IAM. Authenticated API integration reads, `SELECT 1` through the deployed
Prisma client, and authenticated R2 object listing passed before cutover.

The consumer change preserves the two existing Secret targets and all sixteen
bindings while selecting `openbao-postiz-production`. Registry access remains
on its platform store. Optional-provider examples also use OpenBao paths.
Temporary writer configuration is removed after successful staging. Bootstrap
only upserts roles, so live role/policy retirement must additionally be verified.

## Completed 2026-09-27 UTC

All seventeen usable credentials were staged and byte-verified. The namespace
reader passed exact read-only and out-of-scope denial checks. Consumer PR #1220
is deployed; all sixteen bindings freshly reconcile through OpenBao and both
whole-Secret hashes are unchanged. Temporary role, policy and ServiceAccount
are absent, with prior access configuration captured privately.

Backup `20260927T140924Z-c466a0788998` passed isolated restore in 19.843 seconds;
three verified backups are retained and the pruned object is absent. All 33
reviewed GCP records were deleted. After deletion, fresh reconciliation, UI and
registration checks, authenticated integration API reads, database `SELECT 1`,
R2 object listing and unauthenticated denial checks passed. Social-provider
interactive OAuth and publishing were not exercised.
