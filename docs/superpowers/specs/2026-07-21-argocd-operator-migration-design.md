# ArgoCD → argocd-operator Migration — Design Spec

- **Date:** 2026-07-21
- **Environment:** prod GKE `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, namespace `argocd`
- **Author:** platform (sam123ben)
- **Status:** approved (design) — runbook pending review

## 1. Objective

Replace the Helm/Terraform-managed Argo CD with an **argoproj-labs argocd-operator
v0.18.0**–managed `ArgoCD` custom resource named `argocd` in namespace `argocd`,
running **Argo CD v3.3.10** (operator default), tuned for **10k+ Applications**
with zero-sync-storm resilience. Preserve all existing Applications, AppProjects,
SSO, RBAC, repository credentials, Kargo integration, and notifications. Reconcile
Terraform to match (without running `terraform apply`). Execute **in-place on prod**
with full backup and one-command rollback.

## 2. Current state (verified 2026-07-21, read-only)

| Aspect | Finding |
|---|---|
| Install method | Official `argo-helm` chart, driven by Terraform `terraform-new/stacks/05-k8s-bootstrap/main.tf` `helm_release.argocd` |
| **Live Argo CD version** | **v3.4.3** (chart `argo-cd-9.5.21`) — **NOT** v2.13.4 as tfvars claim. Terraform has drifted. |
| Controller | StatefulSet **3 replicas** (tfvars say 2 — drift); implicit sharding |
| Redis | **Single pod** (`argocd-redis`) — SPOF, no HA |
| Repo server | 2 replicas, **crash-restarting** (6–8 restarts) — resource pressure |
| Apps / Projects | **257 Applications**, 15 AppProjects across `argocd/prod`,`devtest`,`pilot` |
| Sync policy | Apps run `automated.prune: false`, `selfHeal: true` — low cascade-delete risk |
| **Resource tracking** | `application.resourceTrackingMethod` **empty → 3.x default = annotation**; live resources carry `argocd.argoproj.io/tracking-id`, **no** instance label |
| Instance label key | `argocd.argoproj.io/instance` |
| SSO | Dual: Dex GitHub connector (`argocd-github-oauth` ESO secret) + Google OIDC (`argocd-oidc-secret`) |
| RBAC | 3.x fine-grained `policy.csv` (incl. `logs`/`exec`), `policy.matchMode: glob`, `scopes: [email]` |
| Scale tuning present | `argocd-cm` has `resource.customizations.ignoreResourceUpdates.*` + `resource.exclusions` |
| Nodes | 3 nodes, one each in `asia-south1-a/b/c` — redis-ha anti-affinity feasible |
| Kargo | Akuity OCI Helm chart `ghcr.io/akuity/kargo-charts/kargo` **v1.10.7**, ArgoCD Application `argocd/prod/infrastructure/kargo.yaml`, `release` AppProject. **No separate operator exists** — Kargo is its own controller. |

### Secrets that MUST survive the cutover
`argocd-secret`, `argocd-oidc-secret`, `argocd-github-oauth` (ESO),
`argocd-notifications-secret` (ESO), `argocd-redis`, `argocd-server-tls`,
`tesserix-kargo-manifests-repo` (ESO), `tesserix-new-k8s-repo`.

## 3. Key decisions (confirmed with owner)

1. **Package via operator** v0.18.0 (owner's explicit choice), executed manually
   (not `terraform apply`); Terraform reconciled afterward.
2. **Argo CD v3.3.10** — the operator's tested/default version. This is a
   **downgrade** from live 3.4.3 (owner accepted the risk after it was flagged).
   Mitigations: full CRD + Application-spec backup, a 3.4-only-field scan before
   cutover, roll-forward-to-Helm-3.4.3 ready.
3. **In-place**, CR named `argocd` (reuse names/labels/Service so the Kong Ingress
   and Kargo wiring are untouched).
4. **Straight to prod**, executed live after runbook review, gated + reversible.

### Operator ↔ Argo CD version coupling (design note)
The operator does **not** upgrade Argo CD on its own upgrade **when `.spec.version`
is pinned**. We pin `.spec.version: v3.3.10`, so future operator upgrades leave
Argo CD untouched until `.spec.version` is deliberately bumped. Only an unset
`.spec.version` would track the operator's bundled default.

## 4. Target architecture

```
argocd-operator-system ns
  argocd-operator-controller-manager  (cluster-scoped; ARGOCD_CLUSTER_CONFIG_NAMESPACES=argocd)
    │ watches
    ▼
argocd ns
  ArgoCD CR "argocd"  ── operator renders ──►  server ×2 · repo ×3 · controller ×3 (sharded)
       redis-ha ×3 + haproxy ×3 · applicationset ×1 · notifications ×1 · dex
  257 Application CRs + 15 AppProject CRs   (adopted via tracking-id annotation, never recreated)
  preserved secrets (see §2)
Kong Ingress argocd.tesserix.app → argocd-server Service  (unchanged)
Kargo (own Helm-installed controller)  (unchanged; talks to argocd ns/instance)
```

## 5. The `ArgoCD` CR (authoritative field list)

`apiVersion: argoproj.io/v1beta1`, `kind: ArgoCD`, `metadata.name: argocd`,
`metadata.namespace: argocd`. **Memory-only resource requests/limits — no CPU
requests or limits anywhere** (workspace convention).

| Concern | CR path | Value |
|---|---|---|
| Image | `.spec.image` | `quay.io/argoproj/argocd` |
| Version | `.spec.version` | `v3.3.10` |
| **Tracking (critical)** | `.spec.resourceTrackingMethod` | **`annotation`** |
| Instance label | `.spec.applicationInstanceLabelKey` | `argocd.argoproj.io/instance` |
| Admin fallback | `.spec.disableAdmin` | `false` |
| **Redis HA** | `.spec.ha.enabled` | `true` (3 redis + 3 haproxy, 1/zone) |
| Redis mem | `.spec.redis.resources` | req 512Mi / lim 1Gi |
| HAProxy mem | `.spec.ha.resources` | req 256Mi / lim 512Mi |
| **Controller shards** | `.spec.controller.sharding.enabled` / `.replicas` | `true` / `3` |
| Shard algorithm | `.spec.controller.env` | `ARGOCD_CONTROLLER_SHARDING_ALGORITHM=consistent-hashing` |
| Processors | `.spec.controller.processors.status` / `.operation` | `50` / `25` |
| kubectl parallelism | `.spec.controller.env` | `ARGOCD_APPLICATION_CONTROLLER_KUBECTL_PARALLELISM_LIMIT=25` |
| Repo timeout | `.spec.controller.env` | `ARGOCD_APPLICATION_CONTROLLER_REPO_SERVER_TIMEOUT_SECONDS=120` |
| Controller mem | `.spec.controller.resources` | req 2Gi / lim 4Gi |
| **Repo scaling** | `.spec.repo.replicas` | `3` |
| Repo mem | `.spec.repo.resources` | req 1Gi / lim 2Gi |
| Repo env | `.spec.repo.env` | `ARGOCD_EXEC_TIMEOUT=300s` |
| Server replicas | `.spec.server.replicas` | `2` |
| Server insecure | `.spec.server.insecure` | `true` (TLS at Kong) |
| Server service | `.spec.server.service.type` | `ClusterIP` |
| OpenShift route | `.spec.server.route.enabled` | `false` |
| Operator Ingress | `.spec.server.ingress.enabled` | `false` (Kong Ingress stays out-of-band) |
| Server mem | `.spec.server.resources` | req 256Mi / lim 512Mi |
| AppSet | `.spec.applicationSet.enabled` / `.replicas` | `true` / `1` |
| Notifications | `.spec.notifications.enabled` | `true` (ESO secret never touched by operator) |
| SSO Dex | `.spec.sso.provider` + `.spec.sso.dex.config` | `dex`; GitHub connector, `clientSecret: $argocd-github-oauth:client-secret` |
| Google OIDC | `.spec.oidcConfig` | `clientSecret: $argocd-oidc-secret:oidc.google.clientSecret` |
| RBAC policy | `.spec.rbac.policy` | full live `policy.csv` verbatim |
| RBAC default | `.spec.rbac.defaultPolicy` | `''` |
| RBAC matcher | `.spec.rbac.policyMatcherMode` | `glob` |
| RBAC scopes | `.spec.rbac.scopes` | `[email]` |
| Exclusions | `.spec.resourceExclusions` | carry over live `resource.exclusions` verbatim |
| Extra cm keys | `.spec.extraConfig` | `admin.enabled`, `exec.enabled`, `application.sync.impersonation.enabled`, `ignoreResourceUpdates.*`, `timeout.reconciliation: 180s` |

### Schema gotchas locked in (verified against operator v0.18.0)
- **No `.spec.controller.replicas`** — replica count comes from
  `.spec.controller.sharding.replicas`.
- **No sharding `algorithm` field** — set via `.spec.controller.env`.
- **No generic `argocd-cmd-params-cm` passthrough** — `server.insecure` comes from
  `.spec.server.insecure`; other cmd-params via component `env` /
  `extraCommandArgs`.
- **`.spec.dex` is deprecated** — use `.spec.sso.dex`.
- **`.spec.oidcConfig`** is the first-class Google-OIDC field (maps to
  `oidc.config` in argocd-cm).
- Operator **owns** `argocd-cm`, `argocd-rbac-cm`, `argocd-secret` — every live
  key must be represented via CR fields/`extraConfig` or it is dropped. Operator
  **preserves** an existing `argocd-secret`'s `server.secretkey` / admin hash
  (generated only when nil). Operator **never** manages `argocd-notifications-secret`
  or repository-type secrets.
- **ESO must NOT own `argocd-secret`** (two writers → fight loop). ESO keeps owning
  the separate repo/oauth/notifications secrets only.

## 6. Cutover sequence (in-place, reversible)

1. **Backup** to `docs/superpowers/backups/argocd-<ts>/` + git branch: all
   `Application`/`AppProject`/`ApplicationSet` CRs, `argocd-cm`/`argocd-rbac-cm`/
   `argocd-cmd-params-cm`, all argocd secrets, the Argo CD CRDs, current
   Deployment/StatefulSet specs, Helm release manifest + values.
2. **3.4-only-field scan** — check the 257 Application CRs + CRDs for fields valid
   only on Argo CD 3.4.x before permitting the 3.3.10 downgrade. Abort if any found.
3. **Freeze** — set `prod-bootstrap` app-of-apps `selfHeal:false` (apps already
   `prune:false`) so nothing auto-reconciles mid-cutover.
4. **Install operator v0.18.0** into `argocd-operator-system` (`make deploy` from
   the v0.18.0 source tarball), add `ARGOCD_CLUSTER_CONFIG_NAMESPACES=argocd` env to
   `argocd-operator-controller-manager`. Wait for it Ready.
5. **Remove Helm-managed workloads only** — delete the Helm Deployments +
   StatefulSet + the three ConfigMaps; **keep** namespace, all CRs, all secrets,
   the CRDs, and the Kong Ingress. (Deliberately not `helm uninstall`, to protect
   Helm-owned secrets; remove the Helm release record separately/last.)
6. **Apply the `ArgoCD` CR** — operator renders the HA stack reusing the same
   resource names/Service; adopts the 257 apps via the tracking-id annotation.
7. **Verify** (§7).
8. **Unfreeze** — restore `selfHeal:true` on `prod-bootstrap`.

### Rollback (any gate fails)
Delete the `ArgoCD` CR → `helm upgrade --install argocd argo-cd --version 9.5.21`
with backed-up values (restores 3.4.3) → re-apply backed-up CMs → confirm apps
re-adopt. Workloads never stopped (prune off), so app pods are unaffected
throughout the window.

## 7. Verification gates (all must pass)

- Every operator-rendered pod `Running`/`Ready` (server ×2, repo ×3, controller
  ×3, redis-ha ×3, haproxy ×3, applicationset, notifications, dex).
- `argocd-server` reachable via Kong at `argocd.tesserix.app`.
- **Google OIDC** login works; **GitHub Dex** login works.
- `argocd app list` shows all **257** apps `Synced`/`Healthy`, diffed against the
  pre-cutover snapshot (no new OutOfSync caused by tracking/label change).
- Force-sync one low-risk app → succeeds.
- **Kargo** promotion end-to-end: a Stage promotion updates an Application image
  tag and triggers sync.
- repo-server no longer crash-looping under HA (watch restarts for 30 min).

## 8. Kargo

No operator exists for Kargo; it remains its own Akuity-Helm-installed controller
(`argocd/prod/infrastructure/kargo.yaml`, v1.10.7). Its Argo CD integration is
unaffected because the instance stays name `argocd` / namespace `argocd`. Only a
post-cutover promotion smoke test is required (§7). Docs drift note: the runbook
mentions 1.9.8 but the live app is 1.10.7 — correct the doc opportunistically.

## 9. Terraform reconciliation (NOT applied)

- Replace `helm_release.argocd` in
  `terraform-new/stacks/05-k8s-bootstrap/main.tf` with an operator-based
  representation (operator install + the `ArgoCD` CR as a manifest resource, or a
  clearly-commented `null_resource` runbook block).
- Update `terraform-new/environments/prod/terraform.tfvars`: drop stale
  `argocd_chart_version=7.7.23` / `argocd_image_tag=v2.13.4`; record operator
  version + Argo CD `v3.3.10`; align controller replicas (3) to reality.
- Explicitly **not run** — reconciliation only, so IaC stops lying about state.

## 10. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| 3.4.3→3.3.10 downgrade rejects/loses CR fields | Medium | CRD + Application backup; 3.4-only-field scan; roll-forward ready |
| Operator overwrites config, drops a live cm key | Medium | Full cm inventory ported to CR/`extraConfig`; diff cm before/after |
| Tracking-method mismatch → mass OutOfSync | High if wrong | `resourceTrackingMethod: annotation` locked to match live |
| ESO vs operator both writing `argocd-secret` | Medium | ESO owns only separate secrets; `$secret:key` refs used |
| redis-ha pods Pending (only 3 nodes) | Low/Med | 1 replica/zone fits; watch scheduling; node headroom check |
| Control-plane downtime during cutover | Expected (brief) | Apps keep running (prune off); minimize window; rollback ready |
| Operator flag drift on non-default Argo version | N/A now | Using operator default 3.3.10 removes this |

## 11. Out of scope

- Argo CD 3.4.x/3.5 upgrade (future, deliberate `.spec.version` bump on a
  3.4-supporting operator release).
- Cluster capacity planning for literal 10k apps (needs far more than 3 nodes;
  tracked separately).
- devtest/pilot migration (prod-only per owner; can follow the same runbook later).
