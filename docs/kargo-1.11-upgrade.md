# Kargo v1.11 Upgrade — What's New and What We Changed

**Status:** DONE — completed 2026-07-30. All Kargo deployments run
`ghcr.io/akuity/kargo:v1.11.0`; the `kargo` Application is Synced/Healthy on
chart `1.11.0`, and all ten Warehouses are Healthy with zero `allowTags`.
**From → to:** chart `1.10.7` → `1.11.0` (`ghcr.io/akuity/kargo-charts/kargo`).
**Upstream notes:** <https://github.com/akuity/kargo/releases/tag/v1.11.0>

---

## 1. Why we were stuck on 1.10.7 in the first place

Kargo upgrades itself: the `platform-tools` Warehouse (`kargo-infra`) subscribes
to the Kargo Helm chart (`>=1.10.6 <2.0.0`), and the `platform-tools-prod` Stage
rewrites `argocd/prod/infrastructure/*.yaml` targetRevisions in this repo, with
auto-promotion **enabled**. So 1.11.0 should have rolled out on its own.

It didn't, because **freight discovery had been failing since 2026-06-12**: the
sealed-secrets chart repo `bitnami-labs.github.io/sealed-secrets` started
returning 404 (the chart moved to `bitnami.github.io/sealed-secrets`), and one
failing subscription fails the *entire* Warehouse — no freight, no promotions,
for every tool on that Warehouse (same failure mode as the mark8ly dangling-tag
incident). The fix is part of this upgrade.

But fixing it in `kargo-manifests` was not enough, because **no Kargo CR spec
change had reached the cluster since the Argo CD 3 upgrade on 2026-06-12** —
see §4a. That had to be fixed first, and it is the reason this upgrade needed
hands on it at all.

## 2. What's new in v1.11 (the parts that matter to us)

- **Auto-promotion holds.** Manually promoting older Freight to a Stage now
  records an explicit *hold*, and auto-promotion respects it. Previously a
  pinned Stage stayed put only by accident of implementation. Resume via the UI
  button or by promoting the origin's current candidate.
- **Faster, cheaper discovery.** Git discovery uses `git ls-remote` to skip
  clones when nothing changed (good for our `tesserix-k8s`-tracking
  subscriptions), and blobless clones are back with automatic fallback.
- **Event-driven promotions.** GitHub PR webhook events wake the relevant
  workflows immediately; `http`, `git-wait-for-pr` and `git-merge-pr` steps take
  an optional `pollInterval` with faster defaults.
- **New promotion steps/options.** `file-write` step; `http` step gains
  `errorExpression` and `proxy`; `git-tag` gains `force`; `delete` accepts
  globs; Promotions get a `kargo.akuity.io/stage` label automatically.
- **Freight ordering by `discoveredAt`** instead of creation time, plus
  `FreightCreated` events and `kargo delete freight` by name/alias.
- **UI**: fully on the REST API, redesigned freight timeline, freight diffs in
  the promote drawer, smoother pipeline graphs.
- **Helm chart**: optional Prometheus `ServiceMonitor`s per component, optional
  `PodDisruptionBudget`s, `api.basePath` / `externalWebhooksServer.basePath`,
  extra containers/volumes per component.

## 3. Breaking changes and our exposure

| Breaking change | Our exposure | Action taken |
|---|---|---|
| `allowTags` / `ignoreTags` on Warehouse subscriptions **hard-fail discovery** in 1.11 (removed in 1.13) | 16 image subscriptions across `kargo-manifests` projects (`infra/observability-apps`, `tesserix-blog`, `tesserix-home`, `mark8ly` ×8 + 1 `ignoreTags`, `support-platform` ×3, `devai`) and the reusable `charts/kargo/kargo-project` chart | Migrated everything to `allowTagsRegexes` / `ignoreTagsRegexes` **before** the version bump — the new fields are already supported by 1.10.7, so the migration is safe on the running version. `ignoreTags` literals became anchored regexes (`main-6308899` → `^main-6308899$`). |
| Auto-promotion now uses explicit holds; previously-pinned Stages auto-promote on first reconcile after upgrade | No Stage is deliberately pinned to old Freight; all auto-promotion-enabled Stages (product dev stages, infra stages) ride latest Freight | None needed. If you *want* a Stage held on old Freight after 1.11: promote the old Freight once manually — that now records a real hold. |
| Helm values `rbac.useDefaultServiceAccount` / `rbac.disableAutomountServiceAccountToken` removed | Not set in `argocd/prod/infrastructure/kargo.yaml` | None. |
| OpenAPI spec corrections; Go client moved to `pkg/x/client/generated` | No custom API clients | None. |
| Legacy Connect/gRPC API removed in **v1.12** (deprecated since 1.9) | UI is on REST as of 1.11; no external gRPC consumers | Upgrade `kargo` CLIs to 1.11 (`brew upgrade kargo` or GitHub releases) — 1.10 CLIs are not guaranteed against a 1.11 server. |

## 4. Changes made (two repos)

**`tesserix/kargo-manifests`** (source of truth for prod Kargo projects):

- All `allowTags:` → `allowTagsRegexes:` (list form), `ignoreTags:` →
  `ignoreTagsRegexes:` (anchored regexes) in `projects/*/warehouses/*.yaml`,
  plus `docs/adding-a-project.md` and the sample-product example.
- `projects/infra/warehouses/platform-tools.yaml` and
  `projects/infra/stages/platform-tools-prod.yaml`: sealed-secrets repo URL
  `bitnami-labs.github.io` → `bitnami.github.io` (both the subscription and the
  `chartFrom(...)` expression — they must agree or the yaml-update step can't
  resolve the chart version from Freight).

**`tesserix/tesserix-k8s`** (this repo):

- `argocd/prod/infrastructure/sealed-secrets.yaml`: same repo-URL fix (the app
  had drifted to `Sync: Unknown` because ArgoCD couldn't fetch the dead index).
- `charts/kargo/kargo-project`: template + values migrated to the regex fields
  (used by the devtest environment; prod projects come from `kargo-manifests`).
- `image-mirror/images.yaml`: `kargo` constraint widened `>=1.10.0 <1.11.0` →
  `>=1.11.0 <1.12.0` (the deliberate-upgrade safety knob, per its own comment).
- This document.

**Not hand-edited:** `argocd/prod/infrastructure/kargo.yaml` `targetRevision`.
Kargo bumped it itself to `1.11.0` in commit `87049131`
("chore(platform-tools): kargo auto-upgrade to current freight"), once the
blockers in §4a were cleared.

## 4a. Why nothing was applying — the real blocker

`argocd-cm` carries `ignoreDifferences` for the Kargo CRDs whose
`jqPathExpressions` are scoped **inside arrays**:

```
kargo.akuity.io_Warehouse: .spec.subscriptions[]?.chart.discoveryLimit  (+ siblings)
kargo.akuity.io_Stage:     .spec.promotionTemplate.spec.steps[]?.retry.timeout
```

The `kargo-projects` ApplicationSet also set `RespectIgnoreDifferences=true`,
which makes those exclusions apply **at sync time** as well as at diff time. An
exclusion inside an array cannot be expressed as a merge patch, so Argo CD
dropped the entire `subscriptions` / `steps` array from the object it applied.
Every sync logged `serverside-applied` and reported "successfully synced", while
`Warehouse/platform-tools` sat at `generation: 1`, last actually mutated
2026-06-12. Self-heal re-ran this 13 times without converging.

The tell: across all six `kargo-project-*` apps the **only** OutOfSync resources
were the ones whose pending change lived inside those two arrays. Every Stage
without an array-scoped change was Synced.

Fix: drop `RespectIgnoreDifferences=true` from
`argocd/prod/apps/release/kargo-projects-appset.yaml` (commit `a79cf3bb`). The
rules stay in `argocd-cm`, so diff-time normalisation of Kargo's webhook-defaulted
fields still works and the apps do not go permanently OutOfSync; only sync-time
respect is off, so a sync applies the full spec from git. Note the sibling
comment in the same file: `ApplyOutOfSyncOnly` was removed earlier for a related
sync-time filtering bug. Treat both as load-bearing.

Two further blockers surfaced once promotions could run again — both were stage
drift, where `kargo-manifests` still wrote back to files deleted from this repo:

| Stage | Wrote to | Deleted by | Fix |
|---|---|---|---|
| `platform-tools-prod` | `argocd/prod/infrastructure/arc-runner-scale-set.yaml` | #100 | step + `argocd-update` entry + `gha-runner-scale-set` subscription removed |
| `observability-prod` | `argocd/prod/infrastructure/fluent-bit.yaml` | #89 (otel-agent replaced it) | same |

And one landmine the first successful promotion tripped: the stage still ran a
`yaml-update` of `argocd.yaml` with the **argo-helm chart version**, but since
the 2026-07-21 operator migration that Application deploys
`charts/argocd-operator` **by path**, so its `targetRevision` is a git ref.
The promotion wrote `9.7.1` into it and left the app in
`ComparisonError: unable to resolve '9.7.1' to a commit SHA`. Nothing was
applied, so Argo CD itself kept running. Restored to `HEAD` in `803f2d54`, and
the step, the `argocd-update` entry and the `argo-cd` subscription were removed
so it cannot recur. **Argo CD versions now move by editing the operator CR, not
by a chart bump — do not re-add that subscription.**

## 5. How the upgrade actually rolls out

1. Push `tesserix-k8s` (chart/template/mirror/doc — no runtime effect yet).
2. Push `kargo-manifests` → the `kargo-projects` ApplicationSet syncs the
   migrated Warehouses and the fixed sealed-secrets URL.
3. The `platform-tools` Warehouse's next reconcile succeeds for the first time
   since June 12 and emits fresh Freight — including **Kargo chart 1.11.x** and
   ~7 weeks of pent-up in-range bumps (keda, cert-manager, argo-cd,
   sealed-secrets 2.19.x, reloader, external-dns, arc, agentgateway, kagent).
4. Auto-promotion runs `platform-tools-prod`: `git-clone` → `yaml-update` of the
   targetRevisions in this repo → `git-commit`/`git-push`
   ("chore(platform-tools): kargo auto-upgrade to current freight") →
   `argocd-update` triggers syncs and waits up to 30 m for convergence.
5. ArgoCD rolls the Kargo deployments to `v1.11.x`. In-flight product
   promotions are unaffected; Warehouse discovery continues on the new
   version because step 2 already removed every deprecated field.

Note the deliberate bundling: the same promotion that brings Kargo 1.11 also
applies the other tool upgrades that were frozen behind the 404. That is this
platform's designed behavior (same-major auto-upgrades, no human in the loop);
if a specific tool needs to be held back, tighten its `semverConstraint` in
`platform-tools.yaml` *before* pushing the fix.

What actually shipped in that bundle on 2026-07-30 (commit `87049131`):

| Chart | Before | After |
|---|---|---|
| kargo | 1.10.7 | **1.11.0** |
| cert-manager | v1.20.2 | v1.21.1 |
| sealed-secrets | 2.18.6 | 2.19.1 |
| reloader | 2.2.12 | 2.2.14 |
| external-dns | 1.14.5 | 1.21.1 |
| kagent / kagent-crds | 0.9.7 | 0.9.12 |

## 6. Verification checklist (after the promotion completes)

```bash
export KUBECONFIG=~/.kube/gke-prod

# Warehouse healthy again, fresh freight present
kubectl get warehouse platform-tools -n kargo-infra \
  -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}'
kubectl get freight -n kargo-infra --sort-by=.metadata.creationTimestamp | tail -5

# Kargo actually on 1.11
kubectl get deploy -n kargo -o jsonpath='{.items[*].spec.template.spec.containers[*].image}'
kubectl get application kargo -n argocd \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.spec.source.targetRevision

# Every product warehouse still discovering (no allowTags stragglers)
kubectl get warehouses -A
kubectl get warehouses -A -o yaml | grep -c "allowTags:"   # must be 0

# sealed-secrets app recovered from Sync: Unknown
kubectl get application sealed-secrets -n argocd \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.spec.source.targetRevision
```

UI spot-checks at <https://kargo.tesserix.app>: freight timeline renders, a
manual promotion of an old Freight shows the new **hold** indicator, pipeline
graphs draw.

Result on 2026-07-30: all six kargo-project apps Synced, all ten Warehouses
Healthy, `allowTags` count 0, Kargo deployments on `v1.11.0`,
`platform-tools-prod` and `observability-prod` promotions Succeeded.

Left open (pre-existing, **not** caused by this upgrade — each is its own fix):

- `cert-manager` app is OutOfSync on `Role`/`RoleBinding cert-manager-tokenrequest`:
  v1.21 dropped them upstream and the app has no `prune: true`, so they linger
  as orphans. Harmless; needs a decision on pruning cert-manager.
- `kargo-support-platform/prod` has errored since ~2026-07-25 on
  `unable to find Argo CD Application "fanzone-mcp"` — the stage still promotes
  to `fanzone-mcp`, `horoscope-mcp` and `gameverse-mcp`, none of which exist as
  Applications (fanzone was parked to zero). Same drift class as §4a's table.
- `kargo-mark8ly/smoke` errors on a step-1 timeout; `uat` has never promoted and
  its stage references nine `mark8ly-uat-*` Applications that do not exist.
- The `argocd` self-management app reports 26 of 27 resources OutOfSync while
  syncs report "all tasks run", and the live objects were last written
  2026-07-21. That is the `ApplyOutOfSyncOnly` + `RespectIgnoreDifferences`
  signature from §4a on Argo CD's own app — worth investigating, but changing
  sync options on the app that manages Argo CD deserves its own change window.

## 7. Worth adopting next (not part of this change)

- **Metrics**: `controller.metrics.serviceMonitor.enabled` (+
  `managementController` / `webhooksServer`) once the ServiceMonitor selector
  on our Prometheus is confirmed to pick them up.
- **PDBs**: `api.podDisruptionBudget.enabled` for the 2-replica API and
  webhooks server.
- **Event-driven promotions**: GitHub webhooks into Kargo would remove the
  5-minute image-discovery latency on product warehouses.
- **Before v1.12** (next upgrade): nothing to do for the gRPC removal, but
  re-read the `git-push` default-policy deprecation from 1.10 — it lands there.
