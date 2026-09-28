# Langfuse OpenBao migration

Track progress in [issue #1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

This access phase defines nine product-prefixed destinations and three
namespace-bound readers: seven service paths in observability, the database
password alone in infra, and two organization keys in evals-operator.
The temporary migration role grants exact-path create/read for 15 minutes;
CAS writes refuse to overwrite different existing values. The threat boundary
is a compromised workload attempting to read another product's credentials.
Readers have no write or list access and cannot authenticate from another namespace.

No consumer cutover or GCP deletion is included in this phase. The existing
DevAI project credentials already live in OpenBao. The shared ClickHouse
password is deferred to its own cohort, avoiding duplicate ownership.

Read-only baseline on 2026-09-28: health and project API return 200 and an
invalid project key returns 401. The organization key returns 401 invalid
credentials, and all five eval onboarding claims are not Ready. Retain both
organization originals pending diagnosis. Both web and worker deployments are now 2/2 Ready. Images and replicas remain unchanged.

Before deletion, archive pinned versions and IAM under KMS, verify every reader,
update the manual OIDC credential writer, verify database/OIDC/provider behavior,
exercise isolated OpenBao restore, remove temporary access, and verify fresh ESO
reads. Preserve the existing service-account binding used for GCS uploads.

GrowthBook is explicitly deferred by the user and must remain untouched.

## Service consumer cutover

The seven service credentials use OpenBao in observability and infra. The two
organization keys remain in GCP until their pre-existing authentication failures
are resolved. The shared ClickHouse credential retains its explicit GCP source
until its separate service-wide migration. The manual OIDC helper now requires
short-lived, exact-path OpenBao write access, uses version-checked CAS writes and
verifies readback. It never falls back to GCP. Running its regeneration option is
a separate credential rotation and is not part of this migration.
