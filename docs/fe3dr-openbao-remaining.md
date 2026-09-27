# fe3dr secret ownership and recovery

OpenBao is the default for fe3dr application secrets. Identifiers start with
`fe3dr-`. GCP Secret Manager retains only the 16 platform exclusions below.
Execution evidence and final deletion status are tracked in
[issue #1159](https://github.com/tesserix/tesserix-k8s/issues/1159).

## Application scope

The reviewed scope contains 62 application sources and 64 OpenBao destinations:
22 initial static/coordinated/BFF sources, 15 legacy application sources,
five shared application dependencies, two development payment sources and
18 runtime sources (10 Cashfree, six vendor-bank fields and two PII keys).

- Production API static/PII: `kv/homechef/homechef-api/fe3dr-*` with the
  read-only `app-homechef_homechef-api` role.
- Production payments: the same product prefix, using
  `runtime-fe3dr-payment` bound only to `homechef/homechef-api`. It may update
  explicit gateway fields and vendor/driver payment fields; metadata deletion
  is restricted to owner-payment paths. It cannot read static, PII, BFF or
  development entries.
- BFF: `kv/homechef/homechef-auth-bff/fe3dr-*`, separate read-only identity.
- Development: `kv/homechef-development/homechef-api/fe3dr-*`, separate
  `read-fe3dr-development` identity. No development workload was activated.
- Shared dependencies use canonical API paths and exact-path namespace readers;
  see [shared consumers](fe3dr-openbao-shared.md).

API and worker select OpenBao independently for `APP_SECRET_STORE` and
`PII_SECRET_STORE`. PII encryption stays enabled; GCP KMS still unwraps the same
DEK. This secret migration does not change the existing PII column migration
phase or remove plaintext columns.

The runtime client handles short-lived Kubernetes authentication. Payout
onboarding waits for secret writes and reports failure rather than false
success. A failed multi-field write requires resubmitting the complete field
set; there is no cross-store/database atomicity guarantee.

## Verification and recovery

The approved handoff paused credential mutations and vendor erasure, drained
old writers, compared all latest source versions, switched payments and
Dwellm8 Cashfree together, then switched PII independently before resuming
writes. No credential rotation, provider activation or real payment was part
of this migration. The existing live Cashfree slot points to sandbox and its
warning remains unchanged.

The final runtime recovery location is
`gs://tesseract-prod-backups-in/openbao/fe3dr-migration/20260927T031554Z/`:

- `runtime-source-recovery.encrypted.json`: 18 sources, metadata/IAM and
  27 enabled versions; KMS encrypt/decrypt and upload/download equality checked.
- `verified-source.snap`: fresh full OpenBao snapshot. An isolated OpenBao
  2.6.2 restore with KMS auto-unseal verified all 64 values and versions;
  uploaded snapshot bytes matched the tested copy.

Earlier batch archives and restore evidence are listed in #1159. Temporary
migration grants and verifier identities are removed after use.

**Rollback after OpenBao accepts new writes requires reverse reconciliation.**
Recreate any deleted GCP sources from encrypted recovery, merge newer OpenBao
values back under a credential-write pause, verify consumers, and only then
select GCP. An environment-variable rollback alone would lose newer values.

## Platform exclusions

- `prod-ghcr-username`, `prod-ghcr-token`.
- `prod-google-client-id`, `prod-google-client-secret` (shared identity bootstrap).
- Four `prod-keycloak-{customer,internal}-admin-{username,password}` entries.
- `prod-temporal-postgresql-password` (shared infrastructure).
- `prod-homechef-cloudflare-api-token` and `prod-homechef-cloudflare-tunnel-token`
  (network/bootstrap/recovery; the live tunnel is already served by OpenBao).
- `prod-homechef-mongodb-backup-gcs-client-email` and
  `prod-homechef-mongodb-backup-gcs-private-key`.
- `prod-postgresql-homechef-ca-cert`, `...-server-cert`, `...-server-key`
  (historical infrastructure TLS).

OpenBao KMS auto-unseal, snapshots and recovery access remain independently
recoverable. Repository visibility must remain public, as recorded in AGENTS.md.
