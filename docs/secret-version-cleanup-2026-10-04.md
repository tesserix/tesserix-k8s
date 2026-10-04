# Older Secret Manager version cleanup — 2026-10-04

Status: completed on 2026-10-04. All 25 approved older versions are confirmed
`DESTROYED`; every retained current version remains enabled and accessible.

Scope: billing account `01C0B7-C8CD85-88B397`, project
`tesseracthub-480811`. The user approved removing verified unused older versions.
No whole secrets or current values are retired by this operation.

## Completed targets

These 25 older versions are byte-for-byte duplicates of the retained enabled
version. Live External Secrets have no numeric pins, inspected repository
references do not pin these older versions, and neither of the storage/app-secrets
Terraform states owns these version IDs. The project has no Cloud Run services or
jobs and no installed SecretProviderClass resource. A 30-day targeted access-log
query found no older-version accesses; this absence is supporting evidence only.

| Secret | Older version destroyed | Retained version |
|---|---:|---:|
| analytics-db-password | 2 | 3 |
| audit-db-password | 2 | 3 |
| documents-db-password | 2 | 3 |
| location-db-password | 2 | 3 |
| notifications-db-password | 2 | 3 |
| prod-cloudflare-tunnel-token | 2 | 3 |
| prod-ghcr-token | 2 | 3 |
| prod-ghcr-username | 2 | 3 |
| prod-global-postgresql-password | 2 | 3 |
| prod-keycloak-customer-admin-password | 2 | 3 |
| prod-keycloak-customer-admin-username | 2 | 3 |
| prod-keycloak-internal-admin-password | 2 | 3 |
| prod-keycloak-internal-admin-username | 2 | 3 |
| prod-marketplace-postgresql-password | 2 | 3 |
| prod-rapidapi-key | 2 | 3 |
| prod-razorpay-key-id | 3 | 4 |
| prod-razorpay-key-secret | 3 | 4 |
| prod-verification-api-key | 2 | 3 |
| prod-verification-email-api-key | 2 | 3 |
| settings-db-password | 2 | 3 |
| subscriptions-db-password | 2 | 3 |
| tenant_router-db-password | 2 | 3 |
| tenants-db-password | 2 | 3 |
| tickets-db-password | 2 | 3 |
| verifications-db-password | 2 | 3 |

## Protection and recovery

Preserve 96 other extra stored versions: 71 have different values with unverified
rollback needs, 22 concern signing/encryption/recovery or dynamic user history,
two are disabled and cannot be archived without changing their state, and one is
the explicitly retained shared Cloudflare source. Disabled versions still incur
storage charges. No additional secret migration or credential rotation is part
of this cleanup.

The private recovery archive is AES-256-GCM encrypted and stored outside Git at
`$HOME/.local/share/tesserix-recovery/secret-versions-20261004/duplicate-versions.aesgcm`.
The separate key is at
`$HOME/.config/tesserix/recovery-keys/secret-versions-20261004.key`.
Directories are private; archive and key files have mode 0600. A separate isolated
Python process decrypted all 25 records and rejected a tampered archive. Each
record contains the original bytes and resource/version metadata. Detailed
private metadata, reader references and operation records are in
`/tmp/tesseract-cost-audit-20261004/secret-version-retirement/`.

Recovery must never print the decrypted payloads. Decrypt into a private working
area, select the archived resource, and add its bytes with `gcloud secrets versions
add SECRET --data-file=PRIVATE_FILE --project=tesseracthub-480811`. Destroyed
numeric version IDs cannot be restored: recovery creates a new version. The
retained current value already equals every approved archived value; adding a
new version is only needed if subsequent current copies have also been lost.

The executor requires the reviewed active account/project and private recovery
files. Immediately before each conditional-etag destruction it rechecks current
metadata, latest version, aliases, protected version IDs, enabled state, exact
payload equality and equality to the decrypted archive. A changed resource,
failed recovery check or unconfirmed destruction stops execution.

## Cost and validation

Each approved version has one replication unit. At the observed October 2
billing rate of approximately AUD 0.0854 per replica-version-month, 25 destroyed
versions save approximately **AUD 2.14/month**, or **AUD 0.07/day**. This is less
than the AUD 10.33 maximum for all 121 extra versions because the remaining
versions have not passed the deletion checks. Billing export reporting is delayed.

Validation run before execution (all passed):

```sh
python3 -m pytest -q tests/test_retire_duplicate_secret_versions.py
ruff format --check scripts/retire_duplicate_secret_versions.py tests/test_retire_duplicate_secret_versions.py
ruff check scripts/retire_duplicate_secret_versions.py tests/test_retire_duplicate_secret_versions.py
mypy --strict scripts/retire_duplicate_secret_versions.py
python3 -m py_compile scripts/retire_duplicate_secret_versions.py
```

The GitHub repository suite passed with 766 tests, four deselected and 48 subtests
([execution PR #1313](https://github.com/tesserix/tesserix-k8s/pull/1313)). Eleven
targeted tests cover deletion after verified recovery and refusal for current,
aliased, pinned, differing, disabled, stale or delayed-destruction targets and
failed archive verification. Secret payloads, hashes, tokens and recovery keys
are not committed.

After execution, all 25 retained current versions passed fresh payload access.
External Secrets remained at 251 Ready; the same two pre-existing failures
(`kora/kora-ai-eval` and `kora/kora-ai-trace-user-key`) remained. No previously
Ready reader regressed. The durable recovery directory also holds the exact
reviewed metadata plan, protected-version inventory, mutation journal and
completion proof. Detailed GCP audit events are captured separately when
available. No live current values were changed.
