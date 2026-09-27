# Remaining fe3dr secret migration

Live metadata review: 2026-09-27, GCP project `tesseracthub-480811`, production
GKE context, namespace `homechef`. Tracks #1159. The baseline inventory has 78
entries; 18 verified static/coordinated sources are already deleted. A fresh
scan found 60 remaining entries and no additional fe3dr entries beyond that
inventory. Values were not printed or stored in this document.

OpenBao is the intended default for **all application secrets**, including
legacy and development entries. Copying a value is staging, not a completed
consumer cutover. Platform exclusions and shared ownership are distinct:
shared application secrets still require coordinated migration.

| Remaining group | Count | Disposition |
|---|---:|---|
| Runtime application secrets | 18 | Staged; API/worker still use GCP. Draft Home-Chef-App#1217 has passing CI, tested pause controls and separate payment/PII backend selectors. Complete writer handoff, onboarding error semantics, release selection, shared Cashfree consumers and PII compatibility/restore tests. |
| BFF identity bundle | 4 | Migrate `gip-web-api-key`, `customer-client-secret`, `business-client-secret`, `internal-client-secret` to the BFF OpenBao prefix, preserving all target values. Delete GCP sources only after recovery capture and post-cutover verification. |
| Legacy/dormant application entries | 15 | Eligible for OpenBao, not platform exclusions. Establish any remaining external/CI/mobile readers and their cutover before deleting GCP sources. No current ESO reader was observed. |
| Development payment entries | 2 | Eligible, with separate development paths and identities. Never put development bank/UPI values under the production API prefix. |
| Shared application dependencies | 5 | Coordinate the single source and all consumers; do not create independent per-product copies that drift during rotation. |
| Platform/infrastructure/recovery | 16 | Retain in GCP; excluded from application migration. |

The expanded application scope is therefore **62 entries** (78 minus 16
platform exclusions), including five shared dependencies. The original 36
candidate count was only the first reviewed execution scope. This table is a
pre-batch inventory; current completion and deletion evidence belongs in #1159.

## Legacy and development application entries

Unless qualified, these have the `prod-homechef-` prefix:

- BFF legacy: `bff-backup-code-hmac-key`, `bff-csrf-secret`,
  `bff-session-secret`, `bff-totp-encryption-key`.
- Old app identity: `keycloak-client-secret`, `internal-keycloak-client-secret`.
- Razorpay: `razorpay-key-id`, `razorpay-key-secret`, `razorpay-webhook-secret`,
  `razorpay-test-key-id`, `razorpay-test-key-secret`, `razorpay-test-webhook-secret`.
- Historical app integration/connection: `google-places-api-key`, `postgresql-url`.
- `shadowfax-api-token` (identified by its application label).
- Two `dev-homechef-vendor-payment-<owner-id>-upi-id` entries; exact owner
  identifiers remain in the private execution inventory.

Enabling a dormant provider is not part of moving its stored credential.
Current project IAM metadata exposes no project-level audit configuration;
absence of access-log evidence would not establish non-use. Current API,
worker and BFF images remain `main-c93dc10`.

## Shared application dependencies

- `prod-resend-api-key`: six products/namespaces consume it.
- `prod-github-feedback-token`: one live ESO consumer observed, but its owning
  chart explicitly documents a cross-repository PAT and one shared rotation
  surface. Treat it as shared until ownership is resolved.
- `prod-support-platform-otto-internal-auth`: four namespace consumers.
- `prod-support-platform-postgres-username` and `...-password`: four namespace
  consumers each.

The API defaults to its OpenBao store once both static and coordinated batches
are enabled. Resend and GitHub feedback explicitly select the shared GCP store
until their coordinated migration. The BFF bundle defaults entirely to its
own OpenBao store. Existing read-only policies remain unchanged.

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
  (historical infrastructure TLS; not application keys).

OpenBao KMS auto-unseal, snapshots and recovery access stay independently
recoverable. No credential rotation, provider activation or production database
restore is implied by this migration.
