# Helivanta deployment-owned feature catalogue

The shared onboarding-service Helm chart publishes a schema-validated ConfigMap
in the dedicated helivanta-growthbook namespace. A scheduled reconciler in that
namespace reads the mounted catalogue and the deployed Helivanta release contract,
then creates missing provider flags. Existing values are owned by console operators
and are never reset, updated or deleted by reconciliation. Missing flags always
start disabled, including flags already eligible for release.

The initial bounds are 100 definitions, a 256 KiB catalogue, one reconciliation
every five minutes, one active job, a 120-second deadline and a 15-second timeout
per provider request. This is an administrative workload below one write/second,
with reads dominating writes. Catalogue provisioning targets convergence within
ten minutes after dependency recovery, not synchronous application availability.
There is no new service, datastore or always-running controller to pay for.

The catalogue is product-scoped, not tenant-scoped. It contains keys, product
owners, dependencies, eligibility and a policy version, never users, tenant IDs,
secrets or clinical information. Helm schema validation and runtime validation
reject unknown fields, duplicates, missing dependencies, cycles and excessive
sizes. Runtime parity with the published release contract prevents a ConfigMap
from inventing releasable product capabilities. A new key needs reviewed application
UI/API bindings and a new release contract before provisioning. Arbitrary draft
controls cannot make application functionality appear.

Console manual creation uses the same approved catalogue and the existing
platform + manage-feature-flags capability, durable command journal and audit.
It creates an absent definition disabled; enabling is a separate, reviewed command
subject to compiled release eligibility and dependencies. Missing provider entries
are shown as not provisioned, rather than hiding them or claiming the provider is
down. Unexpected provider entries/configuration still fail closed.

The scheduled reconciler uses the existing private provider namespace and admin
credential; it neither reads Kubernetes resources through the API nor receives a
Kubernetes API token. It cannot modify the GitOps-owned ConfigMap. Its image is
pinned with the provider release. The credential remains server-only. GrowthBook
is the record of provisioned definitions and revisions; Job completion/logs record
machine outcomes. No credential rotation or database migration is required.

A timeout during create is resolved by reading on the next run; creates are keyed
by the provider's unique flag ID. A conflict is read and validated, never followed
by an overwrite. Preflight validates the complete catalogue and all existing
features before the first create. Partial progress is preserved and retryable;
unavailable provider/configuration stops the run and does not reset live values.
Removed entries are retained for explicit retirement review. Rollback disables the
CronJob and restores prior Git configuration; completed provider definitions are
retained disabled or at their existing operator-selected values.

Rolling compatibility must deploy first: Helivanta ignores only structurally valid,
unconditional, disabled future keys in its own release namespace. Unknown enabled,
foreign, malformed or targeted features are rejected. Unknown keys are removed
before SDK evaluation, so they cannot grant access. The console applies the same
rule for future disabled keys while requiring every known provider entry to have
valid project/environment/type metadata.

Alternatives: a long-lived Kubernetes operator adds RBAC/watch/leader-election
cost without a latency need; imperative console edits to this ConfigMap would be
reverted by Argo; blindly publishing arbitrary keys breaks older SDK consumers.
A bounded scheduled reconciler and manual provisioning of released definitions
avoid those failure modes.

Acceptance requires schema negative tests, actual Helm rendering, replay and
partial-failure tests, provider creation tests, UI creation tests, local builds,
hosted provider integration, deployment health and browser verification. Test code
or a rendered CronJob alone does not establish production acceptance.


## Existing console acceptance and API-only cutover

The deployed console authenticated the authorized platform owner, listed all 22
flags and exercised Pharmacy staff disable and restoration through the durable
journal. Commands `7e49d731-3cd5-4566-9d38-1eafb3859a55` and
`6dd90685-30d5-4595-8fdb-7b801ac25495` succeeded with provider revisions 2 and 3;
the SDK changed from six enabled flags to five and back to six. The original
provider state was restored. These checks authorize the previously approved
API-only cutover; they do not claim browser acceptance of new catalogue creation
or authenticated Helivanta tenant API gating.

The production intent now enables `apiOnly`, retaining the provider backend,
MongoDB and PVCs. The new catalogue CronJob remains disabled pending ordered
compatibility deployment and activation. No live flag deletion or value reset is
part of this change.
