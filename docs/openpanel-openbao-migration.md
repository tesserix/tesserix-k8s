# OpenPanel OpenBao migration

Tracked in https://github.com/tesserix/tesserix-k8s/issues/1209.

Nine OpenPanel credentials map to `openpanel/app/openpanel-*`: admin email,
admin password, cookie secret, database password, three OAuth proxy credentials,
and the root client ID/secret. The analytics operator shares only the root pair
through a separate namespace-bound ESO reader.

Two additional GCP sources are written by the analytics onboarding operator:
`prod-openpanel-devai-client-id` and `prod-openpanel-langfuse-client-id`. They map
to `devai/app/devai-openpanel-client-id` and
`langfuse/app/langfuse-openpanel-client-id`. The DevAI source was recreated by the
old operator after its earlier deletion. Retire the writer before deleting it
again; compare the existing OpenBao value without overwriting a different value.

## Access phase (completed)

The staging policy permits create/read on eleven exact paths, with a
15-minute token. It cannot overwrite an existing different value. OpenPanel's
reader has nine read-only paths; the analytics reader has only the root pair.
The runtime writer has create/read/update only on the two product client IDs,
five-minute tokens, CAS writes and self-revocation. NetworkPolicy and Istio
admit only the analytics operator identity to the OpenBao API.

Archive of all eleven pinned sources, enabled versions, metadata and IAM:
`gs://tesseract-prod-backups-in/openbao/openpanel-migration/20260928T104616Z/gcp-sources.json.gz.kms`.
KMS encryption and remote decryption were round-trip verified. Baseline root API
reads pass, and both source client IDs equal the active OpenPanel clients.
All eleven values were staged with pinned-version equality, including the existing
DevAI value. Both reader identities passed exact read-only and cross-product
denial checks. The temporary staging token was revoked. Operator writer code is
merged in `tesserix/tesserix-operators#17` (`5453663`); the production cutover pins
that image. All eleven GCP originals were deleted after the consumer and provider checks.
The old operator's two project IAM grants and Workload Identity binding were
removed and verified absent. Its Kubernetes identity has no GCP annotation.

The cutover removes the temporary migration ServiceAccount and its bootstrap
policy/role declarations. After reconciliation, remove the corresponding live
OpenBao role and policy, preserving their metadata in the private evidence.
The runtime writer remains constrained to two paths.

## Cutover acceptance

Deploy access first, then the operator image from `tesserix/tesserix-operators`
with its strict OpenBao writer. Switch the three ExternalSecrets through GitOps,
preserve the existing Mark8ly shared credential, and verify fresh ESO reads,
all seven OpenPanel workloads and both onboarding claims. Test isolated OpenBao
restore before deleting verified sources. Reconcile again after deletion and
confirm the GCP sources stay absent. Retire temporary writer permissions and
obsolete operator GCP grants through their owning configuration.

## Verification after cutover

Access PR #1245, operator PR `tesserix/tesserix-operators#17`, consumer PR #1246
and scoped Kubernetes API egress correction #1247 are merged. Both claims are
Ready with canonical OpenBao paths; fresh ESO reads match all three Kubernetes
Secrets byte-for-byte. Seven OpenPanel workload images/replicas and both Argo
source configurations are unchanged.

Database authentication, authenticated root management API reads, both product
client IDs, API/proxy health and dashboard OAuth redirect pass. Google accepts
the real client credentials and rejects an invalid authorization code with
`invalid_grant`; a deliberately wrong client secret returns `invalid_client`.

Backup `20260928T110422Z-33444b1d0388` restored in isolation in 20.983 seconds;
exactly three verified backups remained and pruning was checked. The subsequent backup after staging access retirement,
`20260928T113522Z-f4a747bd07ba`, also restored successfully in 21.66 seconds
with retention and pruning verified. Temporary staging policy, role,
ServiceAccount and tokens are retired. A GitOps operator restart tests fresh
reconciliation with originals absent; final post-deletion evidence is recorded
in issue #1209. The estate-wide issue remains open for the remaining cohorts.
