# Observability application OpenBao migration

Track [issue #1209](https://github.com/tesserix/tesserix-k8s/issues/1209).
The six reviewed sources cover the session signing key, Google OAuth client
ID/secret, and GitHub App ID, installation ID and PEM private key. Their exact
`observability/app/observability-*` targets are in the migration catalog.

A namespace-bound reader can read only those six paths. No wildcard, update,
list or permanent writer permission is added. The existing six Kubernetes keys,
PEM file mount, images and replicas remain unchanged. Temporary staging grants
must be exact-path create/read, short-lived and removed after byte verification.

Read-only baseline passes health and ClickHouse readiness, Google client
validation with an invalid-secret control, GitHub App JWT authentication and
installation lookup. No Terraform owners were found in the storage/app-secrets
states. Archive pinned values/IAM under KMS, verify copies, switch through GitOps,
check fresh ESO reads and functional behavior, and test isolated restore before
deleting originals. Verify another refresh and provider checks after deletion.

The OAuth provisioning runbook now uses OpenBao and create-only CAS. No
credentials are rotated or new users/applications created by this migration.
