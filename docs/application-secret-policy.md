# Application secret storage policy

OpenBao is the default for every new and existing Tesserix product's application,
tenant and user secrets. Use product-prefixed identifiers (`<product>-<secret>`),
separate production/development/UAT paths, and namespace-bound least-privilege
readers. Application configuration may use ESO; tenant/user secrets stay scoped
and are read at runtime. Update secret writers and rotation jobs as well as readers.

OpenBao is also the default for operational platform credentials, including
shared registry/CI, database, identity, DNS and service credentials. The target is
zero GCP Secret Manager records and dependencies, tracked in issue #1209. Do not
create new GCP Secret Manager dependencies. Existing sources are transitional
until their readers, writers, cold-start dependencies and recovery are verified.

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

This policy supersedes older guidance that placed all product-owned credentials
in GCP Secret Manager. Historical runbooks describe their original deployment;
they do not authorize new GCP secrets, including platform credentials. Existing runtime producers
must be migrated and tested before their sources are retired.

## Terraform provisioning guard

The storage and legacy app-secrets stacks freeze the reviewed production GCP
identifier inventory while migration continues. The existing implementation has a
`platform_exception_reason` escape hatch for historical bootstrap dependencies.
That validation capability does not authorize creating new GCP secrets under the
zero-record target; retire the escape hatch with the remaining provisioning
writers. Use OpenBao with reviewed namespace-scoped access instead.

This guard preserves existing unmigrated resources; it does not approve them as
permanent platform exceptions. Retire their declarations alongside migration.
Already-migrated fe3dr database and Kora development signing sources are excluded
from resource, version and IAM loops so old tfvars cannot recreate them. Do not
apply unrelated Terraform drift during a secret migration; review the actual
plan and require only the scoped, intended actions.

Document-intelligence product releases default to OpenBao in both Helm and
Terraform. Create the namespace-bound reader and populate product-prefixed paths
before onboarding; production uses `<product>/app/` and development uses
`<product>-development/app/`. Existing shared Kora processing database readers
are explicitly retained on GCP until their migration is verified in #1209.
A missing backend field must never provision a new application credential in GCP.
