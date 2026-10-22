# CivicLens social identity onboarding

The owner explicitly approved the production identity rollout and dedicated
CivicLens Apple setup on 2026-10-22. The reviewed change is on
`feat/civiclens-v2-onboarding`; activation and live acceptance are tracked below.

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
| Operator `d5172cb` | [release 39734137204](https://github.com/tesserix/tesserix-operators/actions/runs/39734137204), tests and scan passed | `sha256:ab3678239a700c1319da3f0bd10954dda56b73856d8d8f4fb113d33b972ba407` |
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
`app.tesserix.civiclens` was registered with Sign in with Apple enabled. Services
ID `app.tesserix.civiclens.web` is associated with that primary App ID, with domain
`auth.tesserix.app` and return URL `https://auth.tesserix.app/idps/callback`.
Dedicated key `CD8RKNWDJV` is restricted to the CivicLens primary App ID. Its
downloaded PKCS#8/P-256 key and provider configuration were stored at version 1
in the CivicLens Apple production path using CAS=0; metadata confirmed version 1.
No key material was printed, committed, or stored in GCP Secret Manager. Functional
operator reads and provider login remain rollout acceptance checks.

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

## Live rollout receipt and retry repair

PR #1488 activated the broker, OpenBao reader and initial operator. All three
owning Argo applications reconciled Synced/Healthy. The broker has 3/3 ready
replicas and the hosted login 2/2. All 12 existing clients remain Ready at their
current generations with unchanged IDs and declared login URLs. Read-only API
checks confirmed Login V2 for all 12 and preserved Helivanta's custom V2 URL.

The operator's audience-bound OpenBao role read and validated the three production
provider records, including byte equality of the Apple key. Capabilities are
read-only on those paths; development and Kora Apple paths are denied. Apple's
token endpoint accepted the signed client credential and returned `invalid_grant`
for the deliberately invalid authorization code, as expected.

Live reconciliation exposed response-contract bugs in the initial fixture:
provider names are title-cased, provider ownership is `owner`, and the default
`PASSWORDLESS_TYPE_NOT_ALLOWED` enum is omitted. The correction reuses matching
provider IDs and normalizes that omitted enum, avoiding unchanged-policy writes
that Zitadel rejects. Regression tests reproduce both failures and pass after
correction; the complete Zitadel race suite, repository vet and build passed.

CivicLens's isolated organization is `consumer-civiclens`. Initial provider IDs
`396197391444740172` (Google), `396197391629289548` (Apple), and
`396197391763507276` (Facebook) are attached to its login policy. Failed retries
created unlinked duplicate definitions before the correction; no CivicLens users
exist. Public configuration snapshots and pinned OpenBao references are archived
locally at `/private/tmp/civiclens-duplicate-provider-recovery.json`. Cleanup is a
separate explicitly approved deletion, preserving the attached IDs and rechecking
that candidates remain unlinked with no users. Do not report onboarding complete
until the project and both clients have current-generation Ready receipts.

On 2026-10-22, the owner approved deleting the exact 54 unused retry-created
provider definitions. Cleanup verified organization ownership, zero users and the
three original policy links before every deletion. All 54 deletions succeeded;
only the three original providers remain. The mode-0600 recovery inventory is
`/private/tmp/civiclens-duplicate-provider-recovery.json`; deletion receipts are
`/private/tmp/civiclens-provider-cleanup-receipts.json`. OpenBao credentials remain
at version 1, and the namespace/audience-bound reader remains read-only with
development and other-product paths denied.

The next controller retry exposed an incorrect provider-update path in the
initial implementation and fixture. Upstream v4.19.5 requires
`/management/v1/idps/{kind}/{id}`. Correction `d5172cb` reproduces the old HTTP 404
with the corrected fixture, then passes the full Zitadel race suite, repository
vet/build and changed-code lint checks. Full local lint also reports eight
pre-existing findings outside the route correction. The signed release and digest
scan passed before this GitOps pin. Native-client Ready and hosted-login checks
remain live acceptance gates.
