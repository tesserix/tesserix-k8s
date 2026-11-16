# Archived promotion name recovery

The two approved bootstrap records were archived at
`/private/tmp/helivanta-growthbook-promotion-recovery-20261116` before deletion.
The remaining generated hook record has a storage/API key different from its
`metadata.name`. Kubernetes rejects a normal finalizer patch because these names
do not match. Its only remaining finalizer is Argo's hook finalizer.

The recovery admission rule matches one exact API resource name in `kargo-infra`,
one exact existing object name and stage, and the dedicated recovery service
account. It only restores `metadata.name` to the existing `oldObject` value during
an UPDATE. It grants no permissions and changes no business data or finalizers.
The separately scoped Job checks the archived UID, pending deletion and sole hook
finalizer, and uses UID/resourceVersion/finalizer JSON Patch tests. It temporarily
sets the request name to the API key to pass URL validation; admission restores
the original immutable name before normal update validation. The Job verifies
that the approved records are absent after finalization.

The rule is inert for other principals, namespaces, resource names and object
names. Remove this one-record admission rule after the deletion is verified;
retain the archived records and completed recovery Jobs as evidence. New Kargo
promotions must be created without a caller-assigned name through the supported
create flow, not applied as named Argo resources: Kargo assigns its own name.

Validation includes rendered scope/mutation assertions, executable recovery
regressions and Kubernetes server-side dry-run acceptance of the admission policy
and binding. An accepted policy does not prove deletion; verify both original API
keys return 404 and the dedicated stage advances before marking recovery complete.

Recovery completed on 2026-11-16: the scoped finalization Job succeeded, both
original API keys returned NotFound, and the dedicated stage advanced to a valid
promotion. The recovery chart now defaults to disabled so Argo prunes the policy
and binding; its opt-in template remains only for reproducible audit tests. Do
not re-enable it without a separately approved recovery action.

The first resumed promotion exposed Kargo yaml-update scalar-line replacement
truncating inline Helm parameter mappings. The dedicated Application now uses
block mappings for both version and digest, with a regression check preserving
that shape. The malformed generated proposal must be closed and regenerated
from the corrected main branch before any provider upgrade is merged.

The 5.2.1 promotion then exposed the parent's blanket Helm-parameter ignore:
Kargo could synchronize the chart commit while the live Application retained
5.2.0 overrides. The ignore now excludes only `helivanta-growthbook`; application
workload overrides retain their previous Kargo ownership. Release validation
must compare the live Deployment image and ready replica with the promoted
version/digest, in addition to Kargo and Argo health.
