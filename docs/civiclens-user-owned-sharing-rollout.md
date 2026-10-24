# CivicLens user-owned sharing rollout — prepared, not applied

## Target and authorization boundary

Account: `unidevidp@gmail.com`; project: `tesseracthub-480811`; cluster/context:
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`; app namespace:
`civiclens`; product DB: `civiclens_db` on `global/global-postgres`.
Existing API: `https://civiclns-api.tesserix.app`.

The app's AGENTS says "No live cloud changes" and the working agreement requires
explicit approval for migrations and production rollout. This document prepares
that named approval; no cloud changes, migrations or registry push were made.
No public Apple App Store or Google Play release is authorized. The requested
mobile distribution is existing internal CivicLens TestFlight groups only.

## Concrete change

Terraform file: `terraform-new/stacks/03-storage/civiclens-media.tf`.
Read-only targeted plan: `/tmp/civiclens-private-media.tfplan`; JSON review copy:
`/tmp/civiclens-private-media-plan.json`; plan log:
`/tmp/civiclens-private-media-plan.log`. Prepared from current infra base
`c172511f`. Exactly **3 creates, 0 changes, 0 destroys**:

1. Private regional bucket `gs://civiclens-prod-report-media-in` in asia-south1,
   uniform bucket access, public-access prevention, force_destroy=false,
   prevent_destroy=true, seven-day recoverable soft deletion, no public CORS/ACL.
2. Custom role `civiclensReportMediaWriter`: storage.objects.create/get only.
3. Bucket binding to direct Workload Identity principal for KSA
   `civiclens/civiclens-api`, no static credential or project-wide storage grant.

The targeted plan is deliberate to keep this product addition separate from the
shared storage stack's unrelated resources. Review/apply exactly this saved plan;
do not run an untargeted apply with this worktree's default shared variables.
Recheck identity, state and plan immediately before the approved apply.

Helm/GitOps changes add the media bucket env, bounded metadata/HTTPS egress,
256Mi requests/1Gi memory limit per API replica (two replicas), and 100 seconds
termination grace. Istio uses 90-second deadlines for report POST and share-package
POST, 30 seconds for ordinary routes, no automatic retries. Application deadlines
are 75 seconds. No CPU resource settings are introduced.

Existing OpenBao application credentials/readers are unchanged. Google/Apple/
Facebook broker sign-in stays private. User-owned native sharing needs no new
Meta app token, Instagram login or WhatsApp credential in CivicLens. Managed
publishing stays false. The new client has no country-Page selector or demo path.

API source is the tested isolated worktree `/tmp/civiclens-country-pages-qa`.
Only additive migration `0006_private_report_photos.sql` remains. It adds private
object-generation references; no existing data is dropped/replaced. Community
acceptance uses the existing append-only audit log. Current source/photo rules
and all-photo moderator approval remain required for owner exports.

## Ordered approved rollout

1. Commit/push the scoped app and infra changes for reviewed PRs. Verify all native
   Linux AMD64 CI, generated contracts, mobile checks, security policy and release
   container tests before merging. Local AMD64 QEMU linker crashes are not a CI
   pass; Linux ARM64 container/migration/TLS smoke passed separately.
2. Apply only the reviewed three-resource Terraform plan. Verify bucket privacy
   and exact KSA binding, without reading or exposing credential values.
3. Merge the chart/Istio changes first while the old API image is still pinned.
   Confirm Argo sync and existing readiness. Existing image parameters are Kargo
   controlled; do not force an imperative Deployment update.
4. Capture current schema/migration ledger and a fresh recoverable backup under
   approved DB operator credentials. Keep captures in a mode-700 local QA directory
   or the existing protected backup destination, never Git. Last observed CNPG
   state was healthy, backup 24 October 02:10:56 UTC, retention 3d; recheck now.
   Verify the backed-up product can be restored to an isolated scratch DB.
5. Merge the verified API source after the above prerequisites. Existing image CI
   publishes the exact verified digest and Kargo/Argo runs the migrator Sync hook
   before rolling API pods. The new image must contain migration 0006 and the new
   owner-only endpoints. Require a green migration job and both replicas Ready.
6. Verify capabilities: maxPhotos=5, manualSharing=true, current community rules,
   assist/auth unchanged, managed publishing false. Verify unauthenticated report,
   moderation and share exports reject access. Verify private create/get behavior,
   exact-generation reads and default-deny public GCS access. Recheck actual
   storage/owner isolation and all-photo moderation before real report sharing.
7. Upload only the verified real IPA **0.1.5 (12)** to CivicLens ASC app
   `6825667307`; verify VALID and availability in existing internal groups.
   IPA receipt and signature proof are in the app's ignored
   `artifacts/qa/testflight-real-0.1.5/`. No new tester invitations, external beta
   expansion, App Store release or Google Play release.
8. User tests on a real device with Facebook/Instagram/WhatsApp installed, selects
   one/several/all destinations, checks sender identity and captions/photos,
   confirms each post separately, tests cancellation/missing app/retries.
   Native handoff completion cannot establish delivery. Obtain separate explicit
   confirmation before any later public store release.

## Recovery and remaining launch checks

Failed migration keeps the previous ReplicaSet serving. Do not drop the table,
objects, database, bucket or IAM role as rollback. Retain new references/objects;
keep the previous mobile/API pairing available and stop new multi-photo traffic
before an old API rollback. Any live rollback needs its own explicit approval.

Private orphan objects and external user-owned copies require scoped retention/
erasure operations. Runtime cannot list or delete photos. Erasure needs an
approved operator, generation-checked deletion and verification of seven-day GCS
soft-delete and DB-backup expiry; account deletion is not completed by a receipt.
Never log report text/photos, exact coordinates, provider claims or secret values.
Verified routing still covers Melbourne waste/litter only; do not advertise full
Australia/global reviewed authority coverage. Independent moderation is mandatory;
reporters cannot approve their own reports. Public launch retains the existing
privacy/restore/moderation launch gates and is not implied by TestFlight upload.

Pilot cost assumptions: five typical 2MB images ×1,000 reports/day ~300GB/month
new storage, plus reads/egress. Existing ADR estimate ~$68/month storage at year
one, ~$36/month egress at an assumed $0.12/GB for 300GB, not quotes. Confirm real
regional pricing/retention before provisioning. Additional pod memory is 256Mi
requested across both replicas; no new VM/database/cluster is requested.
