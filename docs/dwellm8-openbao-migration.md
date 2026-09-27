# Dwellm8 OpenBao migration

Tracked in [#1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

Ten product-owned sources feed eleven bindings across seven Kubernetes Secrets
in namespace `dwellm8`. Destinations are `dwellm8/app/dwellm8-<secret>`. The
namespace-bound ESO reader receives exactly these read-only paths; the temporary
migration writer in `openbao` receives create/read only with a fifteen-minute TTL.
Pinned versions, CAS=0 and byte readback prevent accidental credential changes.

Shared fe3dr Cashfree sandbox and mail credentials already use their existing
OpenBao ownership paths and scoped grants. Shared registry credentials remain
platform dependencies in GCP. Product database and Temporal passwords belong
in OpenBao; an infrastructure-sounding service name does not exempt them.

Baseline: API 2/2, OpenFGA 1/1 and Temporal 1/1 ready. Public health/readiness and
listing reads return 200; unauthenticated identity lookup returns 401. One initial
Cloudflare 520 was transient; direct and repeated public checks passed. Existing
Twilio placeholders and development-grade payout fingerprint material must be
preserved; this migration does not provision Twilio, enable payments or rotate
fingerprint keys. Do not claim those unconfigured provider flows were tested.

Before deletion: capture metadata/IAM and enabled historical versions in the
KMS-encrypted recovery archive, verify remote download/decryption, stage and
verify all values and reader isolation, switch consumers through GitOps, verify
fresh ESO reconciliation and unchanged whole-Secret hashes, exercise app and
dependency reads, test isolated snapshot restore, and retire temporary access.
Private acceptance evidence is under `/tmp/remaining-openbao-evidence/dwellm8/`.

Dwellm8 PR #388 updates AGENTS/Claude, setup, security/incident guidance and
provider comments to OpenBao. Local diff, formatting and Gitleaks checks passed;
GitHub Actions could not start because the private account's billing/spending
limit blocks jobs. No visibility change or runtime code change was made.

Exact namespace identity and path ACLs protect product credentials from other
workloads; secret values never enter source or logs. No persistent services are
added, so ongoing cost is negligible. Before source deletion rollback can use
old GCP refs; after deletion recovery requires the encrypted archive and KMS key.

## Reviewed consumer cutover

Recovery archive, including metadata/IAM and all enabled historical versions:
`gs://tesseract-prod-backups-in/openbao/dwellm8-migration/20260927T142515Z/gcp-sources.json.gz.kms`.
Remote ciphertext and decrypted content match the captured archive.

All eleven observed bindings retain their existing seven target Secrets. The
API, two CNPG charts and Dwellm8 Temporal select its namespaced OpenBao reader;
the shared platform Temporal deployment retains its existing store. Local API
rendering still omits ESO. The retired Cashfree GCP fallback is removed because
its originals are already deleted; tests now enforce the OpenBao-only behavior.
Product credential staging, live reader verification, writer retirement and
post-cutover functional/restore acceptance remain required before deletion.

## Completion

PRs #1222 and #1223 are deployed. All ten originals were deleted and confirmed
absent after acceptance. Post-deletion fresh reconciliation passed for eleven
bindings and seven target Secrets with unchanged whole-Secret hashes. Workload
images and captured Argo parameters were preserved. Health/readiness/public
listing checks returned 200; unauthenticated identity lookup returned 401.
Temporary migration ServiceAccount, role and policy are absent.

Verified snapshot `20260927T143934Z-7e06dbda07f8` restored in isolation in
20.661 seconds. Three verified backups remained and pruned objects were absent.
The encrypted archive above retains recovery state for the deleted originals.
