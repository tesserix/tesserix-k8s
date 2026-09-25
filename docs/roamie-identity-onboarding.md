# Roamie customer identity onboarding

Status: staged locally, not deployed. This extends the existing HomeChef public
native-client pattern in `k8s/operators/zitadel/claims/`. It does not create a
customer organization per traveller or change TESSERIX password policy.

Roamie is a Zitadel project under TESSERIX (`386377229942128837`). Its `roamie-ios`
and `roamie-android` applications are public native clients with authorization
code + PKCE and explicit refresh grants. The exact callback is
`roamie:/auth/callback`. No client secret belongs in the mobile app.

The accompanying operator change reads adopted client IDs from `oidcConfig` and
reconciles explicitly managed refresh grants/configuration. Existing claims with
no `refreshToken` declaration retain their previous behavior. Deploy the matching
operator image and CRD before the Roamie claims; an old operator ignores the new
field and cannot provide a renewable session. Pin the tested image digest through
the normal release pipeline; do not invent an image tag before it is built.

## Provider prerequisites

- Google connector: `386381087862948767`.
- Apple connector: `389173155337339395`; offered only on iOS.
- Facebook: use approved Meta app `785895364534694`, Tesserix Hub - Prod. Its audited
  domains currently name FanZone. Verify the exact callback produced by the live
  Zitadel connector in Meta Facebook Login settings, preserving existing callbacks
  and domains. Do not assume `roamie:/auth/callback` is Meta's callback: Meta returns
  to Zitadel, which subsequently returns the native authorization code to Roamie.
- The generic OAuth connector has no built-in email/profile mapping in the audited
  Zitadel Login V2 path. Complete and test a supported mapping before declaring the
  Facebook connector usable. Missing or unverified email needs verification;
  a profile `email` field alone is not proof.
- Complete atomic canonical-email uniqueness, verified provider linking and
  project-specific social-only enforcement before customer rollout. The shared
  organization's password setting cannot enforce a policy for one project.

## GitOps rollout sequence

The named production operator/API rollout needs approval under the workspace
AGENTS.md. Target: GCP `tesseracthub-480811`, context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`; identity resources in
`identity-operator` and `zitadel`, API in `roamie`. Recheck active identity and
context immediately before applying. Production was audited using account
`unidevidp@gmail.com`.

1. Release the tested operator and matching CRD through the owning repository.
2. Merge/sync the Roamie project and application claims through Argo CD.
3. Confirm all three claims have `Ready=True` for their current generation. Read
   `ZitadelProject/roamie.status.projectId` and each application's `status.clientId`.
4. Put these public IDs and the verified Facebook provider ID in the existing
   `charts/apps/roamie-api/values.yaml` environment entries. Empty IDs currently
   make the protected API fail readiness, deliberately.
5. Add the **actual Roamie project ID** to the existing Zitadel entry's `audiences`
   in `argocd/prod/infrastructure/istio-auth-policies.yaml`. The host is staged in
   `restrictToHosts`. Do not add a second JWT rule for the same issuer. Until the
   real audience is added, Envoy will reject Roamie bearer tokens before the API.
6. Promote the protected API via Kargo/Argo CD. `/healthz` is liveness; `/readyz`
   requires identity configuration. `/v1/auth/config` exposes public IDs only.
7. Release a new native binary for the added SecureStore/AuthSession dependencies.
   Test Google and Facebook on iOS/Android, and Apple on iOS, including cancellation,
   relaunch, refresh, logout, email verification, duplicate registration and linking.
8. Prove unauthenticated and wrong-project requests cannot invoke billable routes,
   including through the public gateway. Confirm SOS without a session.

Do not create tenant rows, machine principals or schema allocations just to
register a consumer native client. Roamie's customer identities use the existing
Zitadel project/application operator path. A future product backend needing the
onboarding service's machine API must be registered through its normal product
workflow with the required service grants.

## Validation performed

- Operator: Go tests, race tests, vet and build (see implementation handoff).
- Claims: `kubectl kustomize k8s/operators/zitadel/claims`.
- Chart: `helm lint charts/apps/roamie-api` and local template rendering.
- API: Rust tests and clippy; mobile: Jest, typecheck, lint and both native exports.

These are local checks, not evidence of a completed provider sign-in or rollout.
Rollback must not expose the former unauthenticated billable API. Preserve the
protected version or keep affected routes unavailable while fixing configuration.
