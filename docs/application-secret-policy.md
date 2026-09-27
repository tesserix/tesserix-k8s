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
