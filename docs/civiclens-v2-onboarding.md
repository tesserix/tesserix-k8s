# CivicLens social identity onboarding

This change is prepared on `feat/civiclens-v2-onboarding`. It has not been
activated in production. Do not merge before the named rollout approval and
release acceptance below.

## Release acceptance

- Operator main includes consumer organization provisioning and V2 enforcement
  for all managed clients. The image release must finish successfully, and the
  operator image must be pinned by its actual digest in the kustomization.
- The broker patch branch `feat/civiclens-social-v2` is based exactly on deployed
  upstream v4.19.5. Its separate image workflow publishes only to Tesserix. Accept
  the image only after the mapper tests, complete API/console build, and image
  scan succeed. Pin its actual digest in the owning Zitadel Helm values. The
  existing themed Login V2 image can stay at v4.19.5-aurora.3.
- The broker patch maps typed Generic OAuth profile data for Meta on V2. It keeps
  email unverified. There are no legacy V1 mapping actions.

## Credential and identity contract

The operator uses a dedicated read-only OpenBao role,
`zitadel-consumer-provider-reader`, bound to service account `zitadel-operator`
in namespace `identity-operator`, with audience `openbao` and a five-minute TTL.
Its projected token is separate from existing writer/onboarding tokens. Other
OpenBao Kubernetes roles retain their current audience behavior.

An authorized platform writer must populate these exact production paths before
claim reconciliation. Do not overwrite an existing different value, rotate or
revoke another product's provider configuration, or put credential values in git.

- `kv/civiclens/prod/app/civiclens-google-idp-prod`
- `kv/civiclens/prod/app/civiclens-apple-idp-prod`
- `kv/civiclens/prod/app/civiclens-facebook-idp-prod`

The KV `value` string contains provider JSON as documented in the operator's
`operators/zitadel/docs/consumer-organizations.md`. Public provider IDs and client
IDs are not credentials. Existing GCP credential resource names have been located
for Google and Meta; this document does not claim their values have been copied
or that a CivicLens Apple Services ID/private key has been provisioned.

`k8s/operators/zitadel/claims/civiclens.yaml` creates a dedicated CivicLens org,
Google/Apple/Meta connectors, social-only policy and cobalt/light branding, plus
iOS/Android native clients. The public API must use the resulting org/project,
provider, and client IDs from status. Its callback is `civiclens:/auth/callback`.
The claim fails closed when credentials are missing. No manual console setup is
needed or authorized as a substitute for reconciliation.

## Verification after the approved rollout

Check project/client Ready conditions and generation receipts, then inspect the
CivicLens organization in `https://auth.tesserix.app/ui/console/`. Confirm no
password, signup, passkey or domain-discovery controls, and only the declared
social providers. Test first/returning Google and Meta sign-ins on both platforms,
Apple on iOS, cancellation, exact callbacks, branding, and rejection of another
organization's token. Meta needs email access and may need email verification.

The existing shared organization, existing app IDs/client IDs, product custom V2
login URLs, and unmanaged OIDC fields must be preserved. Operator-managed legacy
V1 clients move to V2; unclaimed clients are untouched. Hospital organization
onboarding remains on its separate controller and policy.

CivicLens's requested API origin is `https://civiclns-api.tesserix.app`. The product
repo has the opt-in gateway route and release build origin. Its API/database
rollout is separate: use the existing `global/global-postgres` CNPG cluster with
`civiclens_db`/`civiclens`, runtime/migrator separation, product-scoped OpenBao
secrets, and approved migrations/grants. No new database cluster or load balancer
is required. Public application data remains session-, owner-, and role-checked.
