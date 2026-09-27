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
