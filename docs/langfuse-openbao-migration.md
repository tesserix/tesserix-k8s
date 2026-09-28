# Langfuse OpenBao migration

Tracking: [issue #1209](https://github.com/tesserix/tesserix-k8s/issues/1209).
Access PR #1249 and service cutover PR #1250 are merged.

## Completed service credentials

Seven `prod-langfuse-*` sources were copied without overwrite to
`langfuse/app/langfuse-*`: PostgreSQL password, salt, encryption key, NextAuth
secret, initial-user password and Zitadel client ID/secret. Their GCP originals
were deleted and verified absent on 2026-09-28. Namespace-bound read-only roles
serve the seven paths in observability and the database path alone in infra.
The manual OIDC writer now uses short-lived scoped OpenBao access, CAS and
readback verification; it has no GCP fallback. No credentials were rotated.
The temporary migration token, role, policy and ServiceAccount were removed.

Both ExternalSecrets refreshed from OpenBao after all seven deletions, with
matching generations and byte-identical values. Web and worker remain 2/2
Ready; image overrides, replicas and Argo source configuration were preserved.
Health, project API and OIDC client introspection pass, with invalid-credential
controls rejected. Running signing, encryption and salt values match the
original Kubernetes Secret. No application restart was needed for unchanged
values.

Pinned source versions and IAM recovery state are encrypted at:
`gs://tesseract-prod-backups-in/openbao/langfuse-migration/20260928T120715Z/gcp-sources.json.gz.kms`.
Final backup `20260928T124052Z-bb18068e182c` passed isolated restore in 23.03
seconds. Exactly three backups remain; pruned objects were verified absent.
Restricted acceptance evidence is under
`/tmp/remaining-openbao-evidence/langfuse/`.

## Retained organization credentials

The two `prod-evals-langfuse-org-*` sources were safely copied into their
product-prefixed OpenBao destinations, but the originals and current reader
remain in GCP. They return 401 invalid credentials and all five eval onboarding
claims were already not Ready before migration. Resolve that existing provider
failure before switching the consumer and deleting either original.

The shared ClickHouse credentials are a separate service-wide cohort. GrowthBook
is explicitly deferred by the user and must remain untouched. Full estate
migration remains open in #1209; the post-Langfuse GCP inventory is 360 secrets.
