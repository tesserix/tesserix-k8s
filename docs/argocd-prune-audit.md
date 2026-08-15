# ArgoCD prune audit — prod, 2026-08-15

113 of the 200 apps on `tesseract-prod-in-gke` auto-synced with `selfHeal: true`
and no `prune`. That is the condition that left nine dead ExternalSecrets live
for months (#301): a resource deleted from git stays in the cluster, stays
tracked, and keeps reporting its own health into an app that no longer describes
it. This is the audit of the other 112.

## What "requires pruning" actually means

The controller flagged 35 resources across 8 apps as `requiresPruning`. Only
**two** of them are orphans in the sense that matters:

| App | Flagged | Real | Why the rest are not |
|---|---|---|---|
| `istio-egress-gateway`, `istio-ingress-gateway-internal` | 13 | 0 | Neither can render its source, so ArgoCD compares live against *nothing* and calls every live resource an orphan. Fixed in #304. |
| `zitadel` | 8 | 0 | Helm `pre-install,pre-upgrade` hook resources. Hooks are not part of the manifest set and are never pruned. |
| `openpanel` | 4 | 0 | Three `PostSync` hook resources, plus `Job/openpanel-migrate`, which does not exist in the cluster — a stale entry in `status.resources`. |
| `homechef-api` | 1 | 0 | A `PreSync` hook Job with `hook-delete-policy: BeforeHookCreation`; it persists between syncs by design. |
| `homechef-identity-bootstrap` | 7 | — | The app itself is an orphan with no definition in git; see below. |
| `global-app-of-apps` | 1 | **1** | `Application/argocd/global-secrets` — removed from git, still live. |
| `istio-istiod` | 1 | **1** | `HorizontalPodAutoscaler/istio-system/istiod` — left behind when the chart moved to `autoscaleEnabled: false`. |

An app that cannot render is **not** at risk from auto-sync: the controller only
syncs an app whose status is `OutOfSync`, and logs `Skipping auto-sync:
application status is Unknown` for these. It *is* at risk from a manual sync.
Read a prune audit off `requiresPruning` alone and you will get the wrong answer.

## The two real orphans

`Application/argocd/global-secrets` carries no finalizer and tracks no
resources, so pruning it deletes the Application object only; the Secrets it
once applied are already untracked and stay.

`HorizontalPodAutoscaler istio-system/istiod` is inert — istiod has no cpu
request, so the HPA's only metric reads `<unknown>` and it holds
`desiredReplicas` at whatever is running. Git pins `replicaCount: 2` and the
Deployment runs 2, so removing it changes nothing.

## What got `prune: true`

58 apps, all of which manage only replaceable resources — Deployments,
Services, ConfigMaps, ExternalSecrets, Istio policies, child Applications. For
56 of them the flag has no effect today; they have nothing to prune. It stops
the next deletion from accumulating.

## What deliberately did not

An app whose manifests fail to render **empty** — as opposed to failing to
render at all — would prune everything it owns. For anything holding state that
is not reconstructible from git, that trade is not worth the tidiness:

| Class | Apps | Kind that decides it |
|---|---|---|
| CNPG clusters | `*-postgres` (13) | `Cluster` |
| Other datastores | `homechef-mongodb`, `mongodb-blog`, `support-platform-mongo`, `global-valkey-{cache,queue}` | `StatefulSet`, `PerconaServerMongoDB` |
| CRD owners | `*-crds`, `istio-base`, `keda`, `kargo`, `external-secrets`, `external-dns`, `homechef-mongodb-operator` | `CustomResourceDefinition` |
| PVC owners | `growthbook`, `libretranslate`, `typesense`, `openpanel`, `postiz`, `qdrant`, `opencost`, `nats`, `temporal`, `fingpt-inference`, `support-platform-{embedder,reranker,slm-inference}` | `PersistentVolumeClaim` |
| Namespace owners | `devai-previews`, `support-platform-namespace`, `namespace-protection` | `Namespace` |
| Cluster-wide primitives | `storage-classes`, `argocd`, `prod-bootstrap` | `StorageClass`, `ArgoCD`, `AppProject` |

`agentgateway-crds` and `mark8ly-postgres` already carried a comment saying
prune was omitted on purpose; this audit agrees with both.

`istio-egress-gateway` and `istio-ingress-gateway-internal` are held only until
#304 lands and they render again.

## Left for a decision

Five Applications are live with no definition in git at all, so no app-of-apps
can prune them — four are tracked by the pre-annotation `argocd.argoproj.io/instance`
label, which the controller no longer reads as ownership:

| Application | Source path (gone from git) | Live resources |
|---|---|---|
| `global-secrets` | `sealedsecret/prod/global` | none |
| `homechef-secrets` | `sealedsecret/prod/homechef` | none |
| `tesserix-home-istio-config` | `charts/infrastructure/istio-config` | none |
| `blog-identity-bootstrap` | `charts/apps/identity-bootstrap` | none |
| `homechef-identity-bootstrap` | `charts/apps/identity-bootstrap` | 7 — including a CronJob still firing every 30 minutes |

These are the unfinished half of [`keycloak-decommission-plan.md`](keycloak-decommission-plan.md)
phase 3 step 3 and the sealed-secret retirement: the manifests were deleted from
git, the live objects never were. `homechef-identity-bootstrap` is the one
costing something — its CronJob dials
`keycloak.identity-customer.svc.cluster.local`, which has not resolved since
Keycloak went, and fails a pod every half hour. Nothing consumes the three
`keycloak-*` Secrets it syncs.

Removing them means deleting live Applications by hand — the one case GitOps
cannot reach, because there is nothing in git left to sync.
