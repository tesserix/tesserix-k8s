# Shared application secret cutover

Tracks #1159. Five remaining shared application sources use one canonical value
under `kv/homechef/homechef-api/fe3dr-<source-without-prod-prefix>`. Namespace
readers have exact read-only ACLs; sharing does not make these platform secrets.
The existing API application reader can read the canonical values. Shared
rotation must update this single destination, never independent product copies.

Consumers: homechef, dwellm8, mark8ly, support-platform, tesserix and stockpilot.
Dormant recovery manifests for fanzone, gameverse, horoscope and postsocial also
reference OpenBao, with namespace reader manifests beside their recovery files.
No dormant workload is enabled. Dwellm8's three sandbox Cashfree fields read the
existing fe3dr sandbox pair, pending the separate runtime writer handoff.

Target Kubernetes Secret names, field names, payloads and refresh intervals stay
unchanged. Readiness and byte equality must pass for all live ESO consumers.
No paid email, GitHub issue submission, payment or database mutation is required
for these source-only changes. Deletion requires encrypted source/version/IAM
capture, isolated snapshot restore and fresh source-version checks. Source
archive locations and execution status belong in issue #1159.

When OpenBao is unavailable, ESO keeps the last successfully synchronized target
Secret and reports a refresh failure. Restore OpenBao from the independently
stored KMS-encrypted snapshots. Before reverting to GCP after rotations, first
reconcile the latest canonical value; old GCP versions are not a safe rollback.

Shared source names:
- prod-resend-api-key
- prod-github-feedback-token
- prod-support-platform-otto-internal-auth
- prod-support-platform-postgres-username
- prod-support-platform-postgres-password
