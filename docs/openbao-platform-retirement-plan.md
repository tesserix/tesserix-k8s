# Retire GCP Secret Manager: platform dependency review

Status: read-only discovery; no platform credential cutover or deletion performed.
Tracks https://github.com/tesserix/tesserix-k8s/issues/1209.

The requested target now includes platform secrets, superseding the earlier
steady-state policy that retained platform secrets in Secret Manager. Operational
credentials should use OpenBao, except the shared Cloudflare original retained
by the user on 2026-09-29 (Melbourne). Keep `prod-cloudflare-api-token` in GCP and
a verified copy at `cloudflare/app/cloudflare-api-token` in OpenBao. Its consumers
and Terraform owner stay on GCP; rotations must update and verify both copies.
The other Secret Manager dependencies still require
independent bootstrap and recovery storage. The implementation direction is KMS-encrypted GCS, consistent with the approved
backup storage and the renewed instruction to continue all migrations.

## Observed scope (2026-09-28, before Planning Poker cleanup)

Discovery used account `unidevidp@gmail.com`, project `tesseracthub-480811`, and
context `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`.

- 402 GCP Secret Manager records at this audit; Planning Poker subsequently removed one verified original.
- 256 explicit ExternalSecret data bindings to `gcp-secret-store`, referencing
  149 distinct source names.
- 253 records without an observed explicit ESO data binding. These are not
  assumed unused: runtime clients, CI, operators, dataFrom and dormant products
  need separate inspection.
- One record was added since the previous inventory; no records disappeared.
- Support Platform's four originals remain under the user's explicit retain
  decision until its existing email-provider failures are resolved.

Metadata-only evidence is private under `/tmp/openbao-platform-audit/`. No secret
payload was accessed for this review. Preserve unrelated local `.gitignore`,
`.ignore`, and fe3dr inventory changes.

## Recovery dependency and proposed resolution

`charts/thirdparty/openbao/templates/bootstrap-configmap.yaml` writes initial
recovery material to `prod-openbao-recovery-keys` and reads it during interrupted
bootstrap recovery. `scripts/check_break_glass.py` also depends on that record.
The running seal uses GCP KMS and Workload Identity. KMS is separate from Secret
Manager and must remain available for existing auto-unseal and encrypted backups.

The preferred replacement is a dedicated recovery prefix/bucket in GCS, encrypted
with KMS, accessible using independently managed IAM without a functioning
OpenBao, ESO or Argo installation. An external offline recovery vault is the
alternative. Storing the only recovery copy inside OpenBao creates a circular
dependency and cannot meet the restore requirement.

Recovery shares and bootstrap records need their own retention policy: do not
apply the three-snapshot pruning rule to the only recovery material. Archive
writes must reject accidental overwrites; IAM should distinguish bootstrap
creation, routine backup and emergency human recovery. Do not treat a revoked
initial root token as the break-glass recovery mechanism.

## Migration sequence and acceptance gates

| Batch | Work | Required evidence |
|---|---|---|
| Inventory and writers | Resolve each remaining source's owner, consumers, writers, Terraform ownership and environment | Reviewed source-to-destination mapping; no tenant identifiers in public artifacts |
| Independent recovery | Replace recovery Secret Manager writes/reads, break-glass tooling, IAM and documentation | Interrupted bootstrap recovery plus isolated restore using independent credentials; no GCP SM access |
| Remaining products | StockPilot runtime/user credentials, BeautyAndCruor and reviewed legacy/dormant products; Planning Poker completed | Pinned copy/readback; scope denial tests; app checks; no blind deletion of dormant data |
| Shared operational services | Database, telemetry, analytics, shared provider and service credentials | Every shared consumer switched; fresh ESO and functional dependency checks |
| Cluster delivery/control plane | Registry pulls, Git/Argo/Kargo/Atlantis credentials, identity, DNS and certificate authority dependencies | Reviewed cold-start dependency order and recovery access outside the failed cluster |
| Retire sources and writers | Release Terraform ownership safely, disable old creation/rotation paths, delete only accepted originals | Encrypted recoverable capture, unchanged pinned versions, consumer acceptance and specific deletion authorization |
| Final migration audit | Inspect all Secret Manager records, runtime/CI clients and IAM | Only explicitly retained Cloudflare originals remain, with verified OpenBao copies; all other accepted migration and restore/cold-start gates pass |

A credential being named “platform” is not evidence of a bootstrap dependency.
Conversely, a working warm cluster does not prove cold-start recovery: ESO needs
OpenBao, and restoring those workloads may need registry and Git credentials.
Explicitly resolve those dependencies before deleting their GCP sources.

For each batch, preserve image parameters and unrelated Terraform state. Use
GitOps for desired state; never apply unrelated broad plans. Rollback before
source deletion can restore old references; afterward it requires independent
recovery state and a reviewed restoration procedure. Do not rotate values during
migration unless separately authorized.

Existing OpenBao compute remains in use. Additional GCS/KMS storage and operations
have a cost; exact net savings require version/replica and billing measurements.
The existing twice-daily verified snapshots target a 12-hour backup interval;
retain three verified snapshots. Recovery-material retention is separate. Current
isolated restore measurements are not a cluster-wide disaster recovery RTO.

## Independent recovery implementation

Use a separate `tesseracthub-480811-openbao-bootstrap-prod` bucket and dedicated
`openbao-bootstrap-key` in the existing regional keyring. Enable versioning,
public access prevention, uniform IAM and seven-day soft deletion; apply no
age-based lifecycle rule. Terraform prevents destruction of both bucket and key.
The existing three-snapshot policy remains on the separate snapshot bucket.

The bootstrap service account receives objectCreator/objectViewer on this bucket
and encryption/decryption on the dedicated key. The GCS service agent receives
CMEK access. Routine snapshot backup/test identities receive no new grants.
`recovery_record.py` performs client-side KMS encryption in addition to bucket
CMEK, uses generation-match zero for object creation, accepts identical retries,
rejects different existing records and verifies decrypted remote bytes. Payloads
never enter command arguments or error messages. The canonical object is
`bootstrap/init.json.kms`.

The first infrastructure plan is limited to six new resources (bucket, key and
four IAM memberships). It changes no existing resource and deletes nothing. Do
not apply the full storage-stack plan: unrelated historical drift remains out
of scope. Keep all original recovery data until exact copy/readback, independent
GCP-identity retrieval, bootstrap-consumer cutover and restore checks pass.

Initialisation and interrupted-bootstrap handling still need separate integration
and failure testing before the old Secret Manager reader/writer can be removed.
Never initialise or rekey the production OpenBao as a migration test. A cold-start
must restore existing data and recovery material, not replace them with new keys.


### Recovery storage progress (2026-09-28)

PR #1238 applied exactly six creates, zero changes and zero deletes through a
targeted Atlantis plan. The original recovery record was archived at
`gs://tesseract-prod-backups-in/openbao/independent-recovery-migration/20260928T080610Z/gcp-sources.json.gz.kms`.
The canonical GCS copy passed byte equality and independent GCP-only decrypt
verification. The original was retired in #1240 after consumer rollout and restore acceptance.
The consumer change also grants the existing scheduled GitHub break-glass identity
decrypt-only access to this dedicated key; it already has bucket read access.
This does not grant routine backup/restore-test identities recovery access.


### Independent recovery completed

PR #1239 deployed the GCS bootstrap consumer; #1240 deleted the single recovery
Secret Manager record through a targeted Atlantis apply and reconciled its two
obsolete IAM bindings. Both enabled versions remain in the encrypted migration
archive above. A fresh bootstrap after deletion verified the GCS record and
revoked its temporary token. Independent break-glass also passed with the source
absent. No production initialization or rekey was performed.

Backup `20260928T082137Z-741ed0e3979a` restored in 19.024 seconds, with exactly
three retained snapshots and pruning verified. All 265 deployments and
StatefulSets kept their images and had no readiness regression. Current verified
cleanup is 278 records; 397 GCP Secret Manager records remain. Keep #1209 open.
