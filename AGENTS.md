# Repository visibility

`tesserix/tesserix-k8s` must always remain public. Never make it private, including as part of a temporary public/CI/private workflow. This is a persistent user instruction.

# fe3dr secrets

Use in-cluster OpenBao as the default destination for fe3dr application secrets, with identifiers starting `fe3dr-`. Migrate operational platform credentials under issue #1209; retain existing bootstrap/recovery sources only until their independent replacement is verified. Track remaining consumer cutovers and shared-secret coordination in issue #1159.

# Roamie secrets

Use in-cluster OpenBao for Roamie application secrets, with `roamie-` identifiers and separate production/development paths. Migrate operational platform credentials under issue #1209; retain existing bootstrap/recovery sources only until their independent replacement is verified. See `docs/roamie-openbao-migration.md` and issue #1176.

# Application secret storage

OpenBao is the default for every new and existing Tesserix product's application,
tenant and user secrets. Use product-prefixed identifiers (`<product>-<secret>`),
separate production/development/UAT paths, and namespace-bound least-privilege
readers. Application configuration may use ESO; tenant/user secrets stay scoped
and are read at runtime. Update secret writers and rotation jobs as well as readers.

OpenBao is also the default for operational platform credentials, including
shared registry/CI, database, identity, DNS and service credentials. Retire GCP
Secret Manager dependencies under issue #1209 except explicit user-retained
sources. The shared Cloudflare secret `prod-cloudflare-api-token` must remain in
GCP Secret Manager, with a verified copy at
`cloudflare/app/cloudflare-api-token` in OpenBao. Keep its existing consumers and
Terraform ownership on GCP; do not delete it or disable Secret Manager while this
exception applies. On rotation, update both copies and verify equality. This is
an explicit user exception, not permission to create unrelated GCP secrets.
Other sources are transitional until readers, writers, cold-start dependencies
and recovery are verified.

OpenBao bootstrap/recovery material must remain independently recoverable outside
OpenBao; never keep its only copy inside the system it unlocks. Its GCP sources
remain until an independently accessible replacement is approved and tested.
KMS auto-unseal and encrypted GCS backups are separate from Secret Manager and
remain required. Preserve the explicit retain decision for Support Platform's
four originals until its provider failures are resolved. See
`docs/openbao-platform-retirement-plan.md`.

Migrate one product at a time: archive recoverable state, copy pinned versions
without overwriting different values, switch readers and writers through GitOps,
verify functional behavior and isolated restore, then delete only verified,
approved GCP originals. See `docs/application-secret-policy.md`.
