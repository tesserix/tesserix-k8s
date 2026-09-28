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

## Access phase

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
No source deletion is complete for this cohort.

## Cutover acceptance

Deploy access first, then the operator image from `tesserix/tesserix-operators`
with its strict OpenBao writer. Switch the three ExternalSecrets through GitOps,
preserve the existing Mark8ly shared credential, and verify fresh ESO reads,
all seven OpenPanel workloads and both onboarding claims. Test isolated OpenBao
restore before deleting verified sources. Reconcile again after deletion and
confirm the GCP sources stay absent. Retire temporary writer permissions and
obsolete operator GCP grants through their owning configuration.
