# Kargo v1.11 Upgrade — What's New and What We Changed

**Status:** rolled out via the self-managing `kargo-infra` project (July 2026).
**From → to:** chart `1.10.7` → `1.11.x` (`ghcr.io/akuity/kargo-charts/kargo`).
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

**Not changed:** `argocd/prod/infrastructure/kargo.yaml` `targetRevision`.
That bump is Kargo's own job — see below.

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
