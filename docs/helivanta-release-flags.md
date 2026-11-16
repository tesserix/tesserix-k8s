# Helivanta foundation release flags

Helivanta uses the existing pinned GrowthBook provider with a separate
`Helivanta` project and `helivanta-production` environment. The dedicated reader
selects only that project/environment; its key is never sent to the browser.
The canonical application vocabulary remains in Helivanta's
`contracts/release-capabilities.json`. The checked-in deployment selection is
`charts/thirdparty/growthbook/files/helivanta-release.json`.

The selected foundation enables onboarding, team accounts, core Staff,
department teams, pharmacy setup and pharmacy Staff. Counter, catalogue, stock,
receiving/supplier collaboration, payables, clinical, diagnostic, emergency,
scheduling, payroll and other advanced groups remain off. The application still
requires current IAM, hospital/outlet grants and professional prerequisites;
flags confer no authority.

The GrowthBook PostSync Job uses the same exact version/digest as the provider.
It reads the existing admin credential from a mounted secret, appends its own
project/environment and flags through the vendor API, then writes its reader to
`helivanta/prod/app/helivanta-growthbook-sdk-key` in OpenBao. The namespace-bound
writer can create/read that path, never update an existing different credential.
CAS=0 handles simultaneous first creation; a retry reuses matching resources and
refuses changed settings. Shared organizations, existing projects, environments
and SDK connections are preserved. Job output contains only status and nonsecret
resource identifiers. No management credential reaches the Helivanta namespace.

The reader role is restricted to `helivanta-api` in namespace `helivanta` and
that single KV path. ESO materializes a read-only file in API pods. Egress and
provider ingress allow only API pods to GrowthBook TCP 3100. A host-specific
DestinationRule preserves HTTP/1.1 for the existing provider without a sidecar;
the private connection is confined by network policies. This reuses existing
provider/storage; the only additional compute is one bounded provisioning Job
(50m CPU/64Mi request, 250m CPU/256Mi limit), not a persistent service.

## Delivery and verification

1. Merge this GitOps change after chart renders, secret/policy/network tests and
   provisioning behavior tests pass. OpenBao applies its declared roles/policies.
2. GrowthBook reconciles the PostSync Job. Require a completed Job and an ESO
   SecretSynced condition before promoting the Helivanta application that
   requires this configuration. The default chart leaves the dependency disabled;
   the production Argo values enable it.
3. Use Helivanta's Kargo release workflow for exact application images and chart
   revision. Do not manually edit a live image, Secret or flag payload.
4. Verify the reader payload contains exactly the known Helivanta flags and that
   the effective public/account-bound snapshots agree. Check named owner and
   scoped pharmacy accounts, hidden navigation, deep-link/direct API refusal,
   provider expiry behavior and existing verification/password continuation.
5. Record the image/chart revisions and effective enabled groups in the owner
   release evidence. The Job and passing schemas alone do not establish live
   acceptance.

No provider/Mongo version or schema changes in this rollout. Disabling the
application groups retains identity/security and classified authorized recovery
paths; existing tenant/clinical/stock/financial records are preserved. Reverting
configuration does not delete the dedicated provider records or rotate the
reader. A provider outage closes new optional work after the application's
bounded snapshot lifetime, while baseline recovery remains available.

Local checks: five rendered Helm secret/mount/network/provisioning assertions,
existing GrowthBook image/secret tests, and Node tests of isolated creation,
idempotent retry, conflicting reader/flag refusal and CAS-only persistence.
Live reconciliation and browser acceptance must be recorded after deployment.
