# ArgoCD → argocd-operator Migration Runbook

> **For the operator (human or agent):** this is a **live prod cutover runbook**,
> not a code plan. Each task ends in a **verification gate** (the stand-in for a
> test). **Do not proceed past a gate that fails — go to the Rollback task.**
> Steps use `- [ ]` checkboxes for tracking.

**Goal:** Replace the Helm/Terraform-managed Argo CD (live v3.4.3) with an
argocd-operator v0.18.0–managed `ArgoCD` CR running Argo CD **v3.3.10**, HA-tuned
for 10k+ apps, in-place on prod, preserving all 257 Applications, SSO, RBAC, repo
creds, Kargo, and notifications.

**Architecture:** Install the cluster-scoped operator in `argocd-operator-system`;
remove only the Helm-managed control-plane workloads + config CMs (keep namespace,
all CRs, all secrets, CRDs, Kong Ingress); apply one `ArgoCD` CR that re-renders the
stack under the same names so Kong + Kargo wiring is untouched. Apps are adopted via
the `argocd.argoproj.io/tracking-id` annotation (live 3.x tracking method).

**Tech Stack:** GKE, kubectl, Helm (rollback only), kustomize/make (operator
install), argocd-operator v0.18.0, Argo CD v3.3.10.

## Global Constraints

- Cluster/context: `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, ns `argocd`.
- **Memory-only** resource requests/limits — **no CPU requests or limits anywhere**.
- **`resourceTrackingMethod: annotation`** — matching live; `label` would mass-OutOfSync all 257 apps.
- Argo CD image pinned `.spec.version: v3.3.10` (decouples from operator upgrades).
- No `terraform apply` — Terraform is reconciled as docs only (Task 9).
- No AI/Claude references in any commit or file.
- Git identity for tesserix-k8s: `sam123ben <samyak.rout@gmail.com>`.
- Stop at any failed gate → **Task 10 (Rollback)**.

---

### Task 0: Pre-flight & working directory

**Files:**
- Create: `docs/superpowers/backups/` (gitignored working dir for dumps)

- [ ] **Step 1: Confirm context + identity**

```bash
kubectl config current-context   # MUST print ...tesseract-prod-in-gke
cd tesserix-k8s && git config user.name && git config user.email
git rev-parse --abbrev-ref HEAD  # feat/argocd-operator-migration
```
Expected: prod context; `sam123ben` / `samyak.rout@gmail.com`; on the feature branch.

- [ ] **Step 2: Snapshot current health as the baseline diff target**

```bash
TS=$(date +%Y%m%d-%H%M%S); export TS
BK="docs/superpowers/backups/argocd-$TS"; mkdir -p "$BK"; echo "$BK"
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers | sort > "$BK/apps-baseline.txt"
wc -l "$BK/apps-baseline.txt"   # expect 257
```
Expected: `257` apps captured with their current Sync/Health.

**GATE:** context is prod, identity correct, 257 apps snapshotted. If not, stop.

---

### Task 1: Full backup (rollback source of truth)

**Files:**
- Create: `docs/superpowers/backups/argocd-$TS/*.yaml`

- [ ] **Step 1: Back up all Argo CRs**

```bash
kubectl get applications -n argocd -o yaml   > "$BK/applications.yaml"
kubectl get appprojects  -n argocd -o yaml   > "$BK/appprojects.yaml"
kubectl get applicationsets -n argocd -o yaml > "$BK/applicationsets.yaml" 2>/dev/null || true
```

- [ ] **Step 2: Back up config + secrets + workloads**

```bash
for cm in argocd-cm argocd-rbac-cm argocd-cmd-params-cm; do kubectl get cm $cm -n argocd -o yaml > "$BK/$cm.yaml"; done
kubectl get secret -n argocd -o yaml > "$BK/secrets-all.yaml"
kubectl get deploy,statefulset,svc,cm -n argocd -o yaml > "$BK/workloads.yaml"
kubectl get ingress -n argocd -o yaml > "$BK/ingress.yaml" 2>/dev/null || true
```

- [ ] **Step 3: Back up the Argo CD CRDs (downgrade safety)**

```bash
for crd in applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io; do kubectl get crd $crd -o yaml > "$BK/crd-$crd.yaml"; done
```

- [ ] **Step 4: Back up the Helm release of record (for rollback reinstall)**

```bash
helm -n argocd get values argocd > "$BK/helm-values.yaml" 2>&1 || echo "no helm release named argocd"
helm -n argocd list -o yaml > "$BK/helm-list.yaml"
helm -n argocd get manifest argocd > "$BK/helm-manifest.yaml" 2>&1 || true
```

**GATE:** every file in `$BK` is non-empty (`ls -la "$BK"`; `applications.yaml`
should be large). If backups are incomplete, stop — do not proceed without them.

---

### Task 2: 3.4-only-field scan (downgrade veto)

Verify the live 3.4.3 Application/CRD data has no fields that only exist on 3.4.x
and would be dropped/rejected by 3.3.10.

- [ ] **Step 1: Scan Application specs for known 3.4-only fields**

```bash
grep -nE "sourceHydrator|hydrator|drySource|syncSource|multipleSources.*3\.4" "$BK/applications.yaml" || echo "NONE-FOUND (good)"
```
Expected: `NONE-FOUND (good)`. (`sourceHydrator`/hydrator is the notable 3.4 add.)

- [ ] **Step 2: Confirm no app uses a 3.4-only sync feature**

```bash
grep -nE "hydrate|sourceHydrator" "$BK/applications.yaml" || echo "NONE (good)"
```
Expected: `NONE (good)`.

**GATE:** both scans return NONE. If any 3.4-only field is in use, **stop and
re-decide the version** (the downgrade would lose that field) — return to the
owner before continuing.

---

### Task 3: Freeze auto-reconcile

Prevent apps from reconciling during the control-plane gap. (Apps are already
`prune:false`; we only need to pause `selfHeal` at the root.)

- [ ] **Step 1: Disable selfHeal on the root app-of-apps**

```bash
kubectl patch application prod-bootstrap -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":false}}}}'
kubectl get application prod-bootstrap -n argocd -o jsonpath='{.spec.syncPolicy.automated}'; echo
```
Expected: `{"prune":false,"selfHeal":false}`.

**GATE:** `prod-bootstrap` shows `selfHeal:false`.

---

### Task 4: Install argocd-operator v0.18.0

**Files:**
- Create: `/tmp/argocd-operator-v0.18.0/` (source checkout)

- [ ] **Step 1: Fetch the v0.18.0 source**

```bash
cd /tmp && rm -rf argocd-operator-v0.18.0
git clone --depth 1 --branch v0.18.0 https://github.com/argoproj-labs/argocd-operator.git argocd-operator-v0.18.0
cd argocd-operator-v0.18.0 && git describe --tags
```
Expected: `v0.18.0`.

- [ ] **Step 2: Render the operator manifests (dry-run, do NOT apply yet)**

```bash
cd /tmp/argocd-operator-v0.18.0
kubectl kustomize config/default | tee /tmp/operator-rendered.yaml | grep -E "^kind:|image:" | sort -u | head -40
```
Expected: shows CRDs (`ArgoCD`, `ArgoCDExport`, `NotificationsConfiguration`),
a `Deployment`, RBAC, namespace `argocd-operator-system`, and the operator image.
**Confirm the operator image tag corresponds to v0.18.0.**

- [ ] **Step 3: Apply the operator**

```bash
kubectl apply -f /tmp/operator-rendered.yaml
kubectl -n argocd-operator-system rollout status deploy/argocd-operator-controller-manager --timeout=180s
```
Expected: deployment successfully rolled out.

- [ ] **Step 4: Grant the argocd-ns instance cluster-config scope**

```bash
kubectl -n argocd-operator-system set env deploy/argocd-operator-controller-manager ARGOCD_CLUSTER_CONFIG_NAMESPACES=argocd
kubectl -n argocd-operator-system rollout status deploy/argocd-operator-controller-manager --timeout=120s
kubectl -n argocd-operator-system get deploy argocd-operator-controller-manager -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ARGOCD_CLUSTER_CONFIG_NAMESPACES")].value}'; echo
```
Expected: prints `argocd`.

**GATE:** operator pod `Running`/`Ready`; `ArgoCD` CRD exists
(`kubectl get crd argocds.argoproj.io`); env var set. This step is
**non-destructive** — nothing about the running Argo CD changed yet.

---

### Task 5: Remove Helm-managed control-plane workloads (keep everything else)

> Deletes ONLY the control-plane Deployments/StatefulSet + the 3 config CMs.
> Keeps: namespace, all Application/AppProject CRs, all Secrets, CRDs, Kong Ingress,
> Services (operator re-adopts Services by name). App workloads in other namespaces
> are untouched (they are not owned by these Deployments).

- [ ] **Step 1: Delete the Helm control-plane workloads**

```bash
kubectl delete deploy -n argocd argocd-server argocd-repo-server argocd-applicationset-controller argocd-notifications-controller argocd-dex-server argocd-redis --ignore-not-found
kubectl delete statefulset -n argocd argocd-application-controller --ignore-not-found
```

- [ ] **Step 2: Delete the 3 Helm-owned config CMs (operator will recreate from CR)**

```bash
kubectl delete cm -n argocd argocd-cm argocd-rbac-cm argocd-cmd-params-cm --ignore-not-found
```

- [ ] **Step 3: Remove the Helm release record (secrets preserved)**

```bash
# Do NOT `helm uninstall` (it would delete argocd-secret). Remove the release history only:
kubectl delete secret -n argocd -l owner=helm,name=argocd --ignore-not-found
helm -n argocd list   # expect argocd gone from the list
```

- [ ] **Step 4: Confirm the safety-critical objects still exist**

```bash
kubectl get application -n argocd --no-headers | wc -l          # expect 257
kubectl get secret -n argocd | grep -E "argocd-secret|argocd-oidc-secret|argocd-github-oauth|argocd-server-tls|tesserix-.*-repo|argocd-notifications-secret|argocd-redis"
```
Expected: 257 apps still present; all listed secrets still present.

**GATE:** 257 Applications intact AND all preserved secrets present. If any secret
is missing, **Rollback (Task 10)** before applying the CR.

---

### Task 6: Apply the `ArgoCD` CR

**Files:**
- Create: `charts/argocd-operator/argocd-instance.yaml` (the CR, committed to git)

- [ ] **Step 1: Write the CR**

Create `charts/argocd-operator/argocd-instance.yaml`:

```yaml
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: argocd
  namespace: argocd
spec:
  image: quay.io/argoproj/argocd
  version: v3.3.10

  # --- tracking: MUST match live 3.x (annotation) — label would mass-OutOfSync ---
  resourceTrackingMethod: annotation
  applicationInstanceLabelKey: argocd.argoproj.io/instance
  disableAdmin: false

  # --- HA Redis (3 redis + 3 haproxy, one per zone) ---
  ha:
    enabled: true
    resources:
      requests: { memory: 256Mi }
      limits:   { memory: 512Mi }
  redis:
    resources:
      requests: { memory: 512Mi }
      limits:   { memory: 1Gi }

  # --- application controller: sharded, tuned processors ---
  controller:
    sharding:
      enabled: true
      replicas: 3
    processors:
      status: 50
      operation: 25
    resources:
      requests: { memory: 2Gi }
      limits:   { memory: 4Gi }
    env:
      - { name: ARGOCD_CONTROLLER_SHARDING_ALGORITHM, value: consistent-hashing }
      - { name: ARGOCD_APPLICATION_CONTROLLER_KUBECTL_PARALLELISM_LIMIT, value: "25" }
      - { name: ARGOCD_APPLICATION_CONTROLLER_REPO_SERVER_TIMEOUT_SECONDS, value: "120" }

  # --- repo server: scaled up (was crash-restarting at 2) ---
  repo:
    replicas: 3
    resources:
      requests: { memory: 1Gi }
      limits:   { memory: 2Gi }
    env:
      - { name: ARGOCD_EXEC_TIMEOUT, value: "300s" }

  # --- server: HTTP behind Kong; operator Ingress + OpenShift Route OFF ---
  server:
    replicas: 2
    insecure: true
    service:
      type: ClusterIP
    route:
      enabled: false
    ingress:
      enabled: false
    resources:
      requests: { memory: 256Mi }
      limits:   { memory: 512Mi }

  applicationSet:
    enabled: true
    replicas: 1
    resources:
      requests: { memory: 256Mi }
      limits:   { memory: 512Mi }

  notifications:
    enabled: true
    replicas: 1
    resources:
      requests: { memory: 128Mi }
      limits:   { memory: 256Mi }

  # --- SSO: Dex GitHub connector (clientSecret from ESO secret) ---
  sso:
    provider: dex
    dex:
      config: |
        connectors:
          - type: github
            id: github
            name: GitHub
            config:
              clientID: Iv23liR8HRPwZbCwTeCD
              clientSecret: $argocd-github-oauth:client-secret
              orgs: []
              loadAllGroups: false
              useLoginAsID: false

  # --- Google OIDC (clientSecret from existing argocd-oidc-secret) ---
  oidcConfig: |
    name: Google
    issuer: https://accounts.google.com
    clientID: ""
    clientSecret: $argocd-oidc-secret:oidc.google.clientSecret
    requestedScopes: ["openid", "profile", "email"]

  # --- RBAC (verbatim from live policy.csv) ---
  rbac:
    defaultPolicy: ""
    policyMatcherMode: glob
    scopes: "[email]"
    policy: |
      g, samyak.rout@gmail.com, role:admin
      p, role:admin, applications, *, */*, allow
      p, role:admin, clusters, *, *, allow
      p, role:admin, repositories, *, *, allow
      p, role:admin, projects, *, *, allow
      p, role:admin, logs, get, */*, allow
      p, role:admin, exec, create, */*, allow

  # --- watch reduction carried over from live argocd-cm ---
  resourceExclusions: |
    - apiGroups: ["", "discovery.k8s.io"]
      kinds: ["Endpoints", "EndpointSlice"]
    - apiGroups: ["coordination.k8s.io"]
      kinds: ["Lease"]
    - apiGroups: ["authentication.k8s.io", "authorization.k8s.io"]
      kinds: ["SelfSubjectReview", "TokenReview", "LocalSubjectAccessReview", "SelfSubjectAccessReview", "SelfSubjectRulesReview", "SubjectAccessReview"]

  extraConfig:
    admin.enabled: "true"
    exec.enabled: "false"
    application.sync.impersonation.enabled: "false"
    timeout.reconciliation: "180s"
    resource.customizations.ignoreResourceUpdates.all: |
      jsonPointers:
        - /status
    resource.customizations.ignoreResourceUpdates.argoproj.io_Application: |
      jqPathExpressions:
        - '.metadata.annotations."notified.notifications.argoproj.io"'
        - '.metadata.annotations."argocd.argoproj.io/refresh"'
        - '.metadata.annotations."argocd.argoproj.io/hydrate"'
        - '.operation'
```

- [ ] **Step 2: Apply the CR and watch the operator reconcile**

```bash
kubectl apply -f charts/argocd-operator/argocd-instance.yaml
kubectl -n argocd get argocd argocd -w   # Ctrl-C when Phase=Available
```
Expected: `.status.phase` reaches `Available`.

- [ ] **Step 3: Confirm the app CRDs were not breakingly downgraded**

```bash
for crd in applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io; do echo "== $crd =="; kubectl get crd $crd -o jsonpath='{.spec.versions[*].name}'; echo; done
kubectl get applications -n argocd --no-headers | wc -l   # still 257 — none rejected
```
Expected: CRDs still serve `v1alpha1`; still 257 apps (no CR rejected on re-validation).

**GATE:** `ArgoCD` phase `Available` AND 257 apps still present. If apps dropped or
CRD validation rejects existing CRs → **Rollback (Task 10)**.

---

### Task 7: Verification gates (all must pass)

- [ ] **Step 1: All operator-rendered pods healthy**

```bash
kubectl get pods -n argocd
```
Expected: `argocd-server` ×2, `argocd-repo-server` ×3, `argocd-application-controller` ×3,
`argocd-redis-ha-server` ×3 + `argocd-redis-ha-haproxy` ×3, applicationset ×1,
notifications ×1, dex ×1 — all `Running`/`Ready`, no CrashLoopBackOff.

- [ ] **Step 2: Sync/health diff vs baseline (no new OutOfSync)**

```bash
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers | sort > "$BK/apps-after.txt"
diff "$BK/apps-baseline.txt" "$BK/apps-after.txt" && echo "IDENTICAL (good)" || echo "REVIEW DIFF ABOVE"
```
Expected: `IDENTICAL (good)` — or only expected churn. Any app newly OutOfSync
that was Synced before signals a tracking/config problem.

- [ ] **Step 3: UI + both SSO paths**

```bash
curl -sSf -o /dev/null -w "%{http_code}\n" https://argocd.tesserix.app/healthz   # expect 200
```
Then in a browser: log in via **Google** and via **GitHub** — both succeed.

- [ ] **Step 4: Force-sync one low-risk app**

```bash
# pick a stateless, low-risk app from the list; example:
kubectl -n argocd patch application <low-risk-app> --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl -n argocd get application <low-risk-app> -o jsonpath='{.status.sync.status}{" "}{.status.health.status}'; echo
```
Expected: returns to `Synced Healthy`.

- [ ] **Step 5: Kargo end-to-end**

```bash
kubectl get pods -n kargo   # controller/api Running
```
Then trigger/observe a Kargo promotion (or verify the last promotion still
reconciles): an Application's `image.tag` param updates and the app syncs.

**GATE:** every step above green. Only then continue.

---

### Task 8: Unfreeze

- [ ] **Step 1: Restore selfHeal on the root app-of-apps**

```bash
kubectl patch application prod-bootstrap -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":false}}}}'
kubectl get application prod-bootstrap -n argocd -o jsonpath='{.spec.syncPolicy.automated}'; echo
```
Expected: `{"prune":false,"selfHeal":true}`.

- [ ] **Step 2: Watch 30 min for repo-server stability under HA**

```bash
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -w
```
Expected: no restarts accumulate.

**GATE:** selfHeal restored; repo-server stable (the original crash-loop symptom
is resolved).

---

### Task 9: Commit artifacts + reconcile Terraform (no apply)

**Files:**
- Create: `charts/argocd-operator/argocd-instance.yaml` (from Task 6)
- Create: `charts/argocd-operator/README.md` (install + version-bump notes)
- Modify: `terraform-new/stacks/05-k8s-bootstrap/main.tf` (replace `helm_release.argocd`)
- Modify: `terraform-new/environments/prod/terraform.tfvars` (drop stale 2.13.4)
- Modify: `docs/kargo-deployment.md` (chart 1.9.8 → 1.10.7 note)

- [ ] **Step 1: Commit the CR + README**

```bash
cd tesserix-k8s
git add charts/argocd-operator/
git commit -m "feat(argocd): operator-managed ArgoCD CR (v3.3.10, HA, sharded)"
```

- [ ] **Step 2: Reconcile Terraform to reflect operator install**

Replace the `helm_release.argocd` block in
`terraform-new/stacks/05-k8s-bootstrap/main.tf` with a documented operator
representation (a commented block describing the manual `kubectl kustomize
config/default` install + a `kubernetes_manifest` for the `ArgoCD` CR referencing
`charts/argocd-operator/argocd-instance.yaml`), and update
`terraform-new/environments/prod/terraform.tfvars`:
- remove `argocd_chart_version=7.7.23`, `argocd_image_tag=v2.13.4`
- add `argocd_operator_version=v0.18.0`, `argocd_version=v3.3.10`
- set `argocd_controller_replicas=3` (match reality)

```bash
git add terraform-new/ docs/kargo-deployment.md
git commit -m "chore(argocd): reconcile terraform + docs to operator install (not applied)"
```

**GATE:** `terraform -chdir=terraform-new/stacks/05-k8s-bootstrap validate` passes
(syntax only — do **not** `plan`/`apply`).

---

### Task 10: Rollback (only if a gate failed)

- [ ] **Step 1: Remove the operator-managed instance**

```bash
kubectl delete -f charts/argocd-operator/argocd-instance.yaml
kubectl -n argocd wait --for=delete pod -l app.kubernetes.io/part-of=argocd --timeout=180s || true
```

- [ ] **Step 2: Reinstall the Helm-managed Argo CD 3.4.3**

```bash
helm -n argocd upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version 9.5.21 \
  -f "$BK/helm-values.yaml" --wait --timeout 10m
```

- [ ] **Step 3: Restore config CMs and confirm apps re-adopt**

```bash
kubectl apply -f "$BK/argocd-cm.yaml" -f "$BK/argocd-rbac-cm.yaml" -f "$BK/argocd-cmd-params-cm.yaml"
kubectl -n argocd rollout restart deploy/argocd-server statefulset/argocd-application-controller
kubectl get applications -n argocd --no-headers | wc -l   # 257
kubectl patch application prod-bootstrap -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":false}}}}'
```
Expected: back on 3.4.3, 257 apps Synced/Healthy, selfHeal restored.

**GATE:** live matches the Task 0 baseline. App workloads were never interrupted
(prune off) throughout.

---

## Self-review (spec coverage)

- Objective / HA / sharding / repo scaling / tracking → Task 6 CR ✔
- Backup + rollback → Tasks 1, 10 ✔
- Downgrade safety (3.4-only scan, CRD backup/diff) → Tasks 2, 6.3, 10 ✔
- Operator install + cluster-config scope → Task 4 ✔
- Secret preservation → Task 5.3–5.4, Task 6 (`$secret:key` refs) ✔
- SSO (Google+GitHub), RBAC verbatim → Task 6 ✔
- Verification incl. Kargo + app diff → Task 7 ✔
- Terraform reconcile (not applied) + Kargo doc fix → Task 9 ✔
- No CPU limits; memory-only → CR resources ✔
