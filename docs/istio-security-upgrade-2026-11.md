# Production Istio security upgrade — 10 November 2026

Status: preparatory review. These changes do not bump the deployed Istio version.
Production merging and rollout require separate approval and the deployment
gates below. Preparation and validation used isolated copies of GitHub main,
preserving existing working copies.

## Verified production state

- Active GCP identity: `unidevidp@gmail.com`; configuration: `prod`;
  project: `tesseracthub-480811`.
- Kubeconfig: `~/.kube/gke-prod`; context:
  `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`.
- Kubernetes server: `v1.37.1-gke.2097000`.
- Istiod: two replicas on 1.29.6. CNI and ztunnel: seven ready instances each,
  all on 1.29.6. All 25 observed proxyv2 containers were on 1.29.6.
- Namespaces affected: `istio-system`, `istio-ingress`, `istio-egress`,
  and every ambient workload namespace. Release ownership is `kargo-infra`;
  Argo CD Applications are in `argocd`.
- `agentregistry-system/agentregistry-deny-writes-from-non-bootstrap` contains
  DENY rules with methods: the HTTP/2 method-case advisory's exposure condition.
- Live RequestAuthentication resources fetch external JWKS over HTTPS,
  including Google, GitHub, Zitadel and Kargo Dex signing keys. This matches
  the system-CA-bundle condition in the CA advisory.
- No exploit, certificate forgery, or compromise has been demonstrated by these
  read-only configuration checks. No attack requests were sent to production.
- Kargo's latest Istio promotion attempted 1.29.10 on 22 October and failed
  pushing `HEAD:main`. GitHub requires a PR and `atlantis/apply`; both requirements
  remain intact. The current Warehouse excludes 1.30 and later.

Sources: [2026-007](https://istio.io/latest/news/security/istio-security-2026-007/),
[2026-008](https://istio.io/latest/news/security/istio-security-2026-008/),
[2026-009](https://istio.io/latest/news/security/istio-security-2026-009/).

## Target and unresolved deployment gates

The final target is **1.31.4**, which is patched and supports Kubernetes 1.37.
Istio 1.30.8 is patched but only lists Kubernetes through 1.36 as supported.
Istio 1.29 is end of life and also does not support this Kubernetes version.
See the [support matrix](https://istio.io/latest/docs/releases/supported-releases/).

Ambient CNI and ztunnel support a control plane at the same minor or one minor
ahead. Do not jump the entire mesh from 1.29 to 1.31. The proposed sequence is
1.29.6 → 1.30.8 → 1.31.4, completing all components at each minor before advancing.
The intermediate 1.30.8 installation on Kubernetes 1.37 requires an explicit,
time-bounded compatibility exception and production maintenance approval.
If that exception is unacceptable, use a separately designed migration to a
new supported mesh/cluster; that migration is outside the prepared patches.
See [ambient upgrade sequencing](https://istio.io/latest/docs/ambient/upgrade/helm/).

The configured official Helm index currently contains 1.30.8 but no 1.31.4
entries for base, istiod, CNI, ztunnel or gateway. The direct 1.31.4 chart URL
also returned HTTP 404. This is a deployment blocker even though the official
GitHub 1.31.4 distribution exists. The CLI and full distribution were downloaded
and their published SHA256 checksums verified; their charts rendered locally.
Before rollout, all five 1.31.4 charts must resolve from the configured repository,
or a reviewed, immutable alternative chart source must be prepared and verified.
Do not merge a version bump that Argo CD cannot resolve.

## Prepared changes

In `kargo-manifests`:

- Push to a generated promotion branch, open a PR against main, and wait for
  merge. Do not auto-merge or bypass Atlantis/branch protection.
- Disable automatic Istio promotion. Discover only `>=1.31.4 <1.32.0` patches;
  discovery alone does not upgrade production. Do not manually promote until
  the bridge is complete and the target chart source is verified.
- Include Zitadel's gateway and the shared vendored ingress gateway, previously
  omitted. Add a version annotation to every gateway pod template to force
  reinjection of the patched proxy after istiod upgrades.
- Sync base, istiod, CNI, ztunnel, then the six gateways in separate steps,
  requiring the desired chart revision (or merged Git commit for the vendored
  gateway) rather than accepting health at an unspecified revision.

In `tesserix-k8s`:

- Merge duplicate metadata annotation maps so Kargo authorization survives.
- Authorize the shared and Zitadel gateways for the same stage.
- Disable child Application automatic sync while staged upgrades are in
  progress; Kargo performs the ordered syncs after the approved PR is merged.
- Correct sync waves and remove `Replace=true` from the base chart, avoiding
  replacement of shared mesh resources during an upgrade.
- Leave existing chart versions at 1.29.6 in the preparatory changes.

The shared ingress intentionally retains its existing chart fork, which removes
`istio.io/dataplane-mode: none` for a historical incremental xDS issue. Its
runtime proxy image is injected by istiod. The rollout annotation must produce
new gateway pods with the patched image. Do not claim the vendored template
version itself is upgraded, or remove the fork without a separate traffic check.

## Reviewed execution sequence

1. Review and publish both preparatory changes through PRs. Merge the
   tesserix-k8s safety change before the Kargo promotion change. Confirm all ten
   live Application objects have one annotation map and automatic sync disabled.
   Recheck main-branch rules, required checks and live Kargo generation.
2. Resolve the final chart-publication blocker and approve the compatibility
   exception, maintenance window, blast radius and stop conditions. Confirm
   application error/latency baselines and the operator watching them.
3. Capture non-secret Application specs, proxy images, readiness, mesh policy
   specs, proxy sync status, endpoint probes and the exact Git revisions.
   No secret objects, private keys, tokens or kubeconfig exports belong in Git.
4. Apply the prepared bridge patch **locally**, review it in a PR, and satisfy
   required checks. Its artifact is [`istio-upgrade/01-1.30.8.patch`](istio-upgrade/01-1.30.8.patch). Merge only with the named production approval.
5. Sync base → istiod → CNI → ztunnel → gateways, waiting for desired revision,
   readiness and proxy convergence at every step. With automatic sync disabled,
   a Git version bump alone must not race all components. Inspect waypoint
   Deployments after istiod changes; any that remain old require a separately
   reviewed GitOps rollout of their owning Gateway configuration.
6. Confirm **every** runtime pilot, CNI, ztunnel, gateway and waypoint image is
   1.30.8. Check no residual sidecars are missed. Stop before 1.31 if any remain.
7. Apply [`istio-upgrade/02-1.31.4.patch`](istio-upgrade/02-1.31.4.patch) **after** the bridge patch; review and
   merge through a second upgrade PR. Repeat the same ordered rollout and
   verify every runtime image is 1.31.4. Kargo's repaired manual promotion may
   perform this stage only once all five target charts exist and Freight agrees.
8. Verify proxy synchronization, gateway/waypoint readiness, JWKS retrieval,
   normal authenticated requests, Zitadel opaque-token traffic, HomeChef and
   custom-domain routing. In an isolated test workload using production's
   policy shape, test uppercase and mixed/lowercase HTTP/2 methods and verify
   denied requests never reach the application. Do not probe production write
   endpoints with attack requests. Confirm Kargo Ready/Healthy and Argo CD
   Synced/Healthy at the intended versions; attach the evidence before closing.

Ztunnel updates can interrupt long-lived connections. Maintain gateway and
control-plane availability and roll one node proxy at a time. Do not introduce
node-pool creation, drains, extra public ingress or unrelated resource changes
without separate approval. The prepared changes add no permanent replicas or
cloud services; connection disruption and temporarily slower convergence are
the main operational risks.

Stop on rollout failure, proxy desynchronization, JWKS errors, increased 5xx or
latency, authorization regression, or an unexpected image. Do not automatically
roll back: old versions reopen known vulnerabilities and control/data-plane skew
must remain valid. A rollback requires explicit approval and ordered Git reverts,
with affected data-plane versions restored before the control plane. Reverting
the preparatory Kargo changes would reintroduce the blocked direct-push path.

## Verification completed

- Reproduced direct-push, automatic-promotion, missing-gateway, duplicate-YAML-key
  and sync-order defects with failing regression tests, then passed them.
- `python -m unittest discover -s tests -v` in kargo-manifests: 25 tests passed.
- tesserix-k8s: two Istio safety tests and two Kargo credential tests passed.
- `python scripts/validate-argocd-apps.py`: passed with its 41 accepted baseline
  findings; the unrelated baseline was not changed.
- Ruff check/format and `git diff --check` passed for the new tests/changes.
- Changed Kargo step configs checked against installed 1.11.1 JSON schemas;
  the PR-number expression was represented by its evaluated integer result.
- Official checksum-verified 1.31.4 CLI: `istioctl x precheck --from-version 1.29`
  passed against production. This does not override the support matrix or
  authorize a two-minor jump.
- All ten Applications rendered for baseline 1.29.6, bridge 1.30.8 and target
  1.31.4 with Kubernetes 1.37.1; existing Deployment/DaemonSet/Service selectors
  did not change. The shared gateway uses its retained fork in all renders.
- All five 1.30.8 chart downloads match SHA256 digests in the official index.
  Target renders use charts in the checksum-verified official release bundle,
  **not** the currently missing Helm-repository entries.

Not run: production rollout, runtime security regression requests, live gateway
reinjection and post-upgrade traffic checks. These remain required after approval.

## Approved execution update

The operator approved merging and deploying the staged plan, then explicitly
authorized the admin merge path for the code-owner gate. The release source
blocker is resolved by publishing unmodified Helm chart sources from the
checksum-verified upstream 1.31.4 distribution as packages in
`charts/thirdparty/istio-release`. Its `provenance.json` records the source archive
and package digests. Argo CD and Kargo use the same reviewed public index;
future packages must be introduced through reviewed Git changes and retain
versioned filenames without replacing an existing published package.

The bridge uses official 1.30.8 charts and explicit ordered Argo syncs. Automatic
Istio promotion remains disabled. After all runtime components reach 1.30.8,
manual Kargo promotion proposes the final 1.31.4 PR and performs ordered syncs
only after its reviewed merge. The documented temporary Kubernetes 1.37 support
exception remains a risk of the approved bridge; complete it within this rollout.

### Gateway effective-values correction

Argo CD uses `valuesObject` instead of inline `values`; the initial annotation-only
object hid gateway settings. The first egress sync created an unintended set
of resources named `istio-egress`. The operator approved deleting only that
Deployment, Service, HPA, ServiceAccount, Role and RoleBinding after their
non-secret recreation state was captured. Existing `istio-egressgateway`
resources were retained. All six gateway Applications now store their complete
Helm values, including existing nested annotations, in `valuesObject`. A failing
then passing render regression verifies actual Argo-effective values preserve
Deployment/Service names, selectors and the intended Service exposure. Earlier
render checks combined both value forms and did not expose this precedence
error; use this effective-values regression for subsequent changes.
