# Helivanta clinical sharing activation

Application implementation: [helivanta#1333](https://github.com/tesserix/helivanta/pull/1333).
This is purpose-scoped patient sharing consent, not record-release authorization,
proxy/guardian consent, treatment consent or approved legal notice content.

## Delivered configuration and boundary

Both API and Global API charts default `clinicalConsent.enabled` to false. When
explicitly enabled together, the API receives a 600-second
`helivanta-mediconnect-claim` audience token and a separate 600-second Kubernetes
API token with namespace/CA projection. Automatic token mounting is disabled.
The platform-owned resource-only `helivanta-workload-identity` application binds
the owner service account to only create TokenReview permission;
The Helivanta product project retains its prohibition on cluster RBAC resources.
ClusterRole/Binding names include the release namespace to avoid cross-namespace
collisions. The API requires a discovered explicit control-plane IPv4 `/32` for
private API-server egress. The application handles credential rotation by reopening
projected token files; no token value belongs in Git or operator output.

The API joins the mesh even when document uploads are disabled. The Global API
chart retains STRICT owner mTLS. Its owner DENY has one exact internal-path
exception, and an additional DENY on that path admits only the API owner identity,
including rejection of Global API itself. The separate owner ALLOW admits only
POST `/internal/v1/mediconnect/current-claim`. Other owner routes retain their
Global API boundary. Adding ALLOW alone cannot override the original DENY.

The API Transit role retains its existing staff/emergency policy and gains the
separate `helivanta-clinical-consent` policy. The new policy permits only dedicated
nonexportable HMAC key creation/update with exactly type `hmac`, size `"32"`
**bytes** and plaintext backup disabled, plus HMAC update. Key subresource access
is denied. ESO and all other Kubernetes auth roles do not receive this policy.
The raw string parameter matches the application request and the actual OpenBao
ACL behavior exercised in the application integration tests.

## Activation evidence and remaining live check

Application `dff023ce383f3f478214e13a34fdec8e60b68d18` is deployed through Kargo
promotion `prod.01m5sfrfytv2kmscr5f5ymsahy.54f6b9a`. API, Global API and shell
independent rollout checks passed with two updated/ready replicas each.
`0007_mediconnect` and `0008_patientmaster` were read back from PostgreSQL;
all four new consent/recipient/decision/incident tables force RLS and the three
scale-related exact/approved indexes exist. The workload-identity Application and
OpenBao bootstrap are Healthy/Synced/Succeeded. These are prerequisites, not an
authenticated consent capture or record-release result.

Production values now enable both sides of the clinical-sharing workload link
with the re-observed control-plane address. TokenReview egress selects only API
component pods, excluding the migration Job. Kargo retains ownership of image
parameters. Verify the actual rollout and genuine authenticated isolated-tenant
journey after this activation; do not infer either from this document.

## Rollout sequence and remaining gates

1. Complete application PR CI and merge. Promote the corresponding reviewed image
   through the existing Kargo flow and verify `0008_patientmaster` and the ready
   API/Global API workloads. Existing `helivanta-postgres` health blockers need
   their separately approved resolution; this change does not delete initializer
   Jobs or bypass Argo health checks.
2. Deliver the platform-owned TokenReview RBAC and the new Transit policy/role;
   verify both reconciliation results.
   Preserve staff/emergency cryptographic access. Default-off chart changes do not
   activate the new application calls.
3. Revalidate active GCP account, project, context, namespace, workload images and
   actual Kubernetes API endpoint immediately before activation. Read-only
   discovery on 2026-10-25 observed project `tesseracthub-480811`, context
   `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, namespace `helivanta`
   and control-plane endpoint `172.16.0.2`. The observation is not a static network
   guarantee. Set API production values `clinicalConsent.enabled: true` and the
   confirmed `clinicalConsent.kubernetesApiCIDR`, and set Global API production
   values `clinicalConsent.enabled: true`, in one reviewed GitOps activation.
4. Verify actual mesh denial and identity behavior. Public and Global API identities
   must not reach the internal claim route; wrong audience/caller/token, foreign
   tenant/hospital/subject and unavailable TokenReview must never produce a true
   claim. Confirm only the intended API workload has create TokenReview permission.
5. Use the approved isolated synthetic test organization and genuine authenticated
   patient/registrar/independent-reviewer/recipient accounts. Exercise authority,
   approved notice/recipient, explicit capture, signed receipt, consent gate and
   withdrawal through Global API. Preserve audit/outbox evidence and confirm
   `record_access_authorized:false`. Actual signed-record release is a separate
   owner-controlled story. No real notice text, recipient identity, policy or
   clinical consent is seeded by these charts.

Application outage, stale state, tamper/quarantine, concurrency and rollback
checks run against real local dependencies. Production checks must not create a
shared-service outage to repeat those fault-injection cases. No live activation,
authenticated production journey or regulatory approval is established by a
rendered manifest or a passing chart test.

## Reproduction

`uv run --with pytest --with pyyaml python -m pytest -q
 tests/test_helivanta_clinical_consent.py` covers explicit credentials, RBAC,
control-plane egress, default-off behavior, mandatory owner boundary, strict mTLS,
OpenBao scope and duplicate YAML keys. The broader Helivanta/OpenBao test set also
preserves document, emergency, privacy and Global API behavior.

Run Helm lint on both charts with the feature enabled and use strict native
Kubernetes schema validation on rendered output. The local `kubeconform` check
skips unavailable Istio/ExternalSecret schemas; rendered policy assertions and
actual runtime enforcement verification remain separate evidence.
