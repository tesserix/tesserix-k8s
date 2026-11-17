# Helivanta foundation release flags

Helivanta has a dedicated, private GrowthBook installation in namespace
`helivanta-growthbook`, its own authenticated MongoDB and retained PVCs. It does
not reuse the shared platform provider's organization, credentials or database.
The provider is pinned to GrowthBook 5.2.1 and its immutable image digest; MongoDB
is pinned separately to 7.0.45 and its digest. No public ingress is installed.
Operators can use an authenticated Kubernetes port-forward for maintenance.

A first-install Sync hook generates independent JWT, encryption, MongoDB and
admin credentials in memory and writes them once with OpenBao CAS=0. Retries
validate existing credentials and never rotate them. ESO readers and bootstrap
writers are namespace-bound and restricted to exact Helivanta paths. The
PostSync hook uses the supported first-install API, creates the sole Helivanta
organization and renames its unused default project through the supported API.
It refuses foreign projects and changed reader scope. In console-managed mode, it preserves controlled boolean flag changes and rejects unsupported targeting. The standard
`production` environment avoids a second project or custom environment. Shared
GrowthBook seeding is disabled; shared products are untouched.

The six enabled groups are onboarding, team accounts, core Staff, department
teams, pharmacy setup and pharmacy Staff. All other configured groups remain off.
The canonical application vocabulary is Helivanta's
`contracts/release-capabilities.json`; the deployment selection is
`charts/thirdparty/growthbook/files/helivanta-release.json`. Availability flags
never confer IAM authority or bypass tenant, hospital, outlet or professional
prerequisites.

Only the SDK reader reaches the Helivanta API, through a read-only ESO file at
`/var/run/growthbook/sdk-client-key`. The backend evaluates bounded snapshots;
expired/unavailable provider state closes optional workflows. Baseline identity,
password and security recovery remain available. The browser receives evaluated
capabilities rather than provider credentials. Dedicated namespace default-deny
network policies admit API TCP 3100, internal MongoDB, DNS and seed-to-OpenBao.
The API uses an exact-host DestinationRule for the private HTTP provider.

Deployment order: reconcile OpenBao roles and network access, reconcile the new
provider/bootstrap/seeder, verify actual SDK payload and ESO SecretSynced, then
promote API/shell through Helivanta's Kargo release workflow. Never promote the
new production API while its required SDK file is absent. The dedicated Kargo
stage updates only this installation's exact image pin through a reviewed PR.

Recovery limits: retained disks and the independently backed-up OpenBao store
preserve state across pod replacement. A dedicated MongoDB off-cluster backup
and restore drill has not yet been verified; retained PVCs alone are not a
backup. Do not claim disaster-recovery readiness. Seeder recreates the declared
foundation configuration in a fresh provider but a changed reader requires
explicit credential rotation review.

Validation includes rendered Helm isolation/auth/mount/network tests, Node tests
for CAS-only credentials, default-project adoption, idempotency and conflict
refusal. CI, live reconciliation, actual SDK payload and browser evidence must
be recorded separately; hook completion alone does not prove acceptance.


## Console control plane

The companion tesserix-home change adds Feature flags → Helivanta. Its platform-api
uses a separate management key at
`helivanta/prod/app/helivanta-growthbook-management` (OpenBao KV v2), delivered only
through the `openbao-platform-api-production` namespaced ESO reader. The seeder
creates it once, persists with CAS0 and refuses to duplicate/rotate it after a
partial failure. The reader and management keys are distinct.

GrowthBook 5.2.1 requires paid advanced-permissions for project/environment key
restrictions. The supported OSS management credential is an admin key confined to
the sole Helivanta organization in the dedicated provider instance. It can manage
that provider; project/environment restrictions are enforced by the fixed console
adapter rather than by a paid provider role. The browser never receives this key.
Neither it nor feature flags confer hospital/staff/tenant permissions.

The `manage-feature-flags` capability is declared on the existing platform-console
project, without automatic user or machine grants. Write actions require both it
and `platform`, current session verification, expected revision, a reason and an
idempotency key. Failed or uncertain writes retain their command/audit history.

Rollout order after explicit production approval: apply application DB migration
0058; reconcile OpenBao policy, provider/seeder, management ExternalSecret and
capability declaration; verify SecretSynced without printing values; release
platform-api and console through the existing Kargo lane; assign the new role to
an explicitly verified operator and refresh their session. Test console read,
unauthorized writes, controlled publish, SDK propagation and Helivanta UI/API gates.
The GrowthBook chart is pinned by Kargo; advancing its chart revision requires the
owning Kargo promotion, not an imperative application patch.

`apiOnly: false` remains the production intent until that acceptance passes. A
later approved GitOps/Kargo promotion can set it true, running only GrowthBook's
back-end supervisor entry while retaining MongoDB, API, PVCs and probes. Do not
scale the GrowthBook deployment to zero. Retain command history and keys during
application rollback; revert a flag only through an attributable new command.
