# Retained Cloudflare original and OpenBao copy

The user explicitly requested dual storage on 2026-09-29 (Melbourne).
Retain `prod-cloudflare-api-token` in GCP Secret Manager and its existing
Terraform owner. Keep cert-manager and external-dns reading their current GCP
source. Do not include this source in migration deletion batches or disable the
Secret Manager API while this dependency remains.

Copy the pinned version to `cloudflare/app/cloudflare-api-token`, field `value`,
using temporary exact-path create/read access with a maximum 15-minute lifetime.
Archive metadata, IAM and enabled versions under KMS, refuse a differing existing
OpenBao value, verify byte equality and revoke/remove all temporary access.
Run a verified snapshot and isolated restore after copying. No permanent reader or writer is needed
for this recovery copy; no runtime consumer is being switched.

GCP remains the current source of truth. This one-time copy does not automatically
synchronize later rotations. Any approved rotation must update both destinations
and verify equality; never silently overwrite a differing destination during a
migration. Track the retained exception and verification in issue #1209.

Read-only baseline: the current token is active, zone reads succeed and an
invalid token is rejected. Both controller namespaces are Ready. Separate Fanzone
and Atlantis tokens are not changed by this copy operation.

Completed: the pinned source was copied and byte-verified; all temporary access
was removed. Both GCP consumers, payloads, images, replicas and Argo settings
remain unchanged. The original is enabled and its Terraform owner is retained.
Archive: `gs://tesseract-prod-backups-in/openbao/cloudflare-migration/20260928T140842Z/gcp-sources.json.gz.kms`.
Post-copy backup `20260928T141031Z-162687324e42` passed isolated restore in 20.737
seconds, with exactly three verified backups retained and pruning confirmed.
