# Application secret storage policy

OpenBao is the default for every new and existing Tesserix product's application,
tenant and user secrets. Use product-prefixed identifiers (`<product>-<secret>`),
separate production/development/UAT paths, and namespace-bound least-privilege
readers. Application configuration may use ESO; tenant/user secrets stay scoped
and are read at runtime. Update secret writers and rotation jobs as well as readers.

GCP Secret Manager is reserved for critical platform/bootstrap/recovery secrets:
OpenBao recovery material, shared registry/CI access, infrastructure restore
credentials and shared control-plane authority. Product database credentials,
OAuth client secrets, session/signing keys and provider API keys belong in OpenBao.
Never treat a product's own "platform-api" service name as a platform exception.

Migrate one product at a time: archive recoverable state, copy pinned versions
without overwriting different values, switch readers and writers through GitOps,
verify functional behavior and isolated restore, then delete only verified,
approved GCP originals. See `docs/application-secret-policy.md`.

This policy supersedes older guidance that placed all product-owned credentials
in GCP Secret Manager. Historical runbooks describe their original deployment;
they do not authorize new GCP application secrets. Existing runtime producers
must be migrated and tested before their sources are retired.

## Terraform provisioning guard

The storage and legacy app-secrets stacks freeze the reviewed production GCP
identifier inventory while migration continues. New entries are rejected unless
`platform_exception_reason` explicitly explains a critical shared platform,
bootstrap or recovery dependency (20–256 characters). The reason is stored as
`tesserix.io/platform-secret-reason` metadata; never put credential values there.
Product database passwords, signing keys and provider credentials do not qualify.
Use the OpenBao scaffold and product namespace reader instead.

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
