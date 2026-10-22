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

Accepted releases (2026-10-22):

| Component | Accepted workflow | Immutable digest |
|---|---|---|
| Operator `8e09079` | [release 39724585022](https://github.com/tesserix/tesserix-operators/actions/runs/39724585022), tests and scan passed | `sha256:e092189d7a152dc2a366ada533fcafdea8edcbd6e4e1ed258f555f89ac436119` |
| Broker `29986e1b8` | [build 39724595193](https://github.com/tesserix/zitadel/actions/runs/39724595193), provider/V2 tests, API/console build and scan passed | `sha256:22ab1fb4abe6a5f279c5509fa2bbb10358a2fc9fb479af013235add8af1188ac` |

Both digests are pinned on this branch. Helm rendering confirms the broker
Deployment and both setup Jobs use the accepted image; the hosted Login V2 image
remains `v4.19.5-aurora.3`. Kustomize rendering and the three onboarding tests pass.

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
IDs are not credentials. Google and Meta were copied after explicit production-copy approval on
2026-10-22. Both destination writes used CAS=0 and returned version 1; metadata
confirmed current version 1. Pinned sources were `prod-google-client-id` version 3,
`prod-google-client-secret` version 3, `prod-facebook-app-id` version 2, and
`prod-facebook-app-secret` version 2. The Meta app ID was checked against the
reviewed public ID `785895364534694`. Source values and versions were unchanged.
A functional operator read and real provider login remain rollout acceptance checks.

Apple Developer was inspected under Tesserix team `2CRHRRYBPL`. The shared
Zitadel provider uses Services ID `com.tesserix.signin.web` and key ID
`946A8XWHKB`; OpenBao metadata has no Apple-named entry for that key. The migrated
HomeChef and Kora Apple private keys are valid, but belong to different registered
keys. They have not been copied or changed. A dedicated CivicLens App ID
`app.tesserix.civiclens` with Sign in with Apple is prepared at Apple's final
registration screen. Creation is pending action-time approval. The proposed
Services ID is `app.tesserix.civiclens.web`, associated with that primary App ID,
with domain `auth.tesserix.app` and return URL
`https://auth.tesserix.app/idps/callback`. Store the downloaded key only in the
CivicLens production path above; do not put it into Git or GCP Secret Manager.

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
