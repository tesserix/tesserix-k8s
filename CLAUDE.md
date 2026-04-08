# Claude Reference Guide — tesserix-k8s

This file is the single source of truth for Claude when working on any Tesserix repository.
Always read this before making any changes.

## Cluster Access

```bash
export KUBECONFIG=~/.kube/gke-prod
```

Always set this before running any kubectl or argocd commands.

---

## Git Identity

Use whatever git identity is already set on the active user's machine.
**Do NOT override `git config user.name` / `user.email`** — commits should
be attributed to the developer who is actually driving the work.

- **NEVER** include `Co-Authored-By: Claude` or any Claude/Anthropic/AI reference in commit messages.
- **NEVER** mention Claude, Copilot, or any AI tool in commit messages, PR descriptions, or code comments.

---

## No Manual kubectl apply — ArgoCD Only

**NEVER** use `kubectl apply`, `kubectl create`, `kubectl patch`, `kubectl edit`, or `kubectl set` to deploy or modify cluster resources directly. All changes must go through ArgoCD:

1. Make changes in this repo (Helm charts, values, external-secrets, ArgoCD app definitions)
2. Commit and push to `main`
3. ArgoCD auto-syncs (or trigger manually: `kubectl patch app <name> -n argocd --type merge -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}'`)

**Why:** Manual applies drift from Git state, get overwritten by ArgoCD self-heal, and are not auditable. The only exception is emergency debugging (e.g., `kubectl logs`, `kubectl describe`, `kubectl exec` for read-only investigation).

**Key ArgoCD patterns:**
- **Helm charts:** `charts/apps/<service>/` — templates + values
- **ArgoCD apps:** `argocd/prod/apps/<project>/` — app-of-apps pattern
- **External Secrets:** `external-secrets/prod/<namespace>/` — GHCR secrets, DB passwords via GCP Secret Manager
- **Istio config:** `charts/thirdparty/istio-config/` — namespace labels, mTLS, gateway config
- **Namespace labels** (e.g., `istio-injection=enabled`): managed by `istio-config` chart, not manual `kubectl label`

---

## Repository Conventions

### Commit Messages

Use conventional commits:

```
feat: short description
fix: short description
chore: short description
docs: short description
refactor: short description
```

- Keep the first line under 72 characters.
- Add a blank line then a body for multi-line messages.
- No emojis in commit messages.

### Branch Naming

```
feat/short-description
feature/short-description
bugfix/short-description
hotfix/short-description
```

---

## GitHub Actions & CI/CD

### Public/Private Repo Toggle for Builds (MUST FOLLOW)

The `tesserix` GitHub org has **limited Actions minutes** for private repos.
Every CI build requires a **public→build→private** cycle. This is **mandatory** for every push.

```bash
# Step 1: Make repo public BEFORE pushing
gh repo edit tesserix/<repo> --visibility public --accept-visibility-change-consequences

# Step 2: Push code (triggers CI) or trigger manually
git push origin main
# OR for manual trigger:
gh workflow run ci.yml --repo tesserix/<repo> --ref main

# Step 3: Wait and monitor CI — do NOT make private until green
gh run list --repo tesserix/<repo> --limit 3
gh run view <run-id> --repo tesserix/<repo>
# To see step details:
gh run view --job=<job-id> --repo tesserix/<repo>

# Step 4: Once CI is fully green, make repo private
gh repo edit tesserix/<repo> --visibility private --accept-visibility-change-consequences
```

**Rules:**
- Never leave repos public after CI completes
- If CI fails, fix the issue, push again (repo stays public), wait for green, then make private
- Always check all steps are green before switching to private
- The visibility change takes a few seconds — if push fails with "repo disabled", wait 5s and retry

### CI Workflow Pattern (Next.js apps)

All Next.js apps use the same CI pattern:
- Lint → Docker build → Push to GHCR → GKE/Knative deploy → Trivy scan
- Docker build uses `--secret id=NODE_AUTH_TOKEN` for `@tesserix/web` package
- Deployment via `kubectl patch ksvc <service> -n <namespace>` (Knative)
- Image naming: `ghcr.io/tesserix/<service-name>:<tag>`

### CI Workflow Pattern (Go services)

- `go vet` → Unit tests → Docker build → Push to GHCR + GAR → Cloud Run deploy → Trivy scan
- Private Go modules via `GOPRIVATE=github.com/tesserix/*` and `go-private-token` secret

### Required GitHub Secrets

| Secret | Purpose | Source |
|--------|---------|--------|
| `PKG_READ_TOKEN` | NPM `@tesserix/*` packages from GitHub Packages | GCP: `prod-ghcr-token` |
| `GITHUB_TOKEN` | Automatic — GHCR push, PR operations | GitHub built-in |

### GCP Workload Identity (for CI → GKE)

```
Provider: projects/849928263410/locations/global/workloadIdentityPools/github-pool/providers/github-provider
SA: github-actions@tesseracthub-480811.iam.gserviceaccount.com
Cluster: tesseract-prod-in-gke
Region: asia-south1
```

---

## GCP Secret Manager

**Project:** `tesseracthub-480811`

### Naming Convention

```
{env}-{service}-{secret-name}
```

Examples:
- `dev-blog-mongodb-uri`
- `prod-ghcr-token`
- `dev-auth-bff-session-secret`

### Accessing Secrets

```bash
# List secrets
gcloud secrets list --project=tesseracthub-480811 --filter="name:<search>"

# Read a secret
gcloud secrets versions access latest --secret=<name> --project=tesseracthub-480811

# Create a new secret
gcloud secrets create <name> --project=tesseracthub-480811 --replication-policy=automatic
echo -n "value" | gcloud secrets versions add <name> --project=tesseracthub-480811 --data-file=-
```

### Key Tokens

- `prod-ghcr-token` / `prod-ghcr-username` — GHCR auth for pulling/pushing images and `@tesserix/*` npm packages
- `go-private-token` — GitHub PAT for Go private module access

---

## Helm Charts (tesserix-k8s)

### Structure

```
charts/apps/
├── common/          # Library chart — shared templates (_helpers.tpl, _gcp-secrets.tpl)
├── global-config.yaml       # Dev shared config (GCP project, workload identity, etc.)
├── global-config-prod.yaml  # Prod overrides
├── <service>/
│   ├── Chart.yaml           # Must depend on common chart
│   ├── values.yaml          # Dev defaults
│   ├── values-prod.yaml     # Prod overrides
│   └── templates/           # K8s manifests
```

### Template Checklist (new service)

Every service Helm chart should include:
- [ ] `deployment.yaml` — with health probes, security context, emptyDir volumes for readOnlyRootFilesystem
- [ ] `service.yaml` — ClusterIP
- [ ] `serviceaccount.yaml` — with Workload Identity annotation
- [ ] `ingress.yaml` — Kong (dev) / Istio (prod)
- [ ] `externalsecret.yaml` — GCP Secret Manager integration
- [ ] `network-policy.yaml` — default deny + explicit allows
- [ ] `authorization-policy.yaml` — Istio RBAC
- [ ] `scaledobject.yaml` — KEDA autoscaling (conditional)
- [ ] `pdb.yaml` — PodDisruptionBudget (prod only, conditional)

### Common Chart Helpers

Use these in templates:
- `{{ include "common.labels" . }}` — standard K8s labels
- `{{ include "common.selectorLabels" . }}` — pod selector labels
- `{{ include "common.podAnnotations" . }}` — Istio sidecar config

---

## ArgoCD

### App Manifests

```
argocd/
├── dev/
│   ├── apps/global/<service>.yaml
│   ├── infrastructure/
│   └── projects/tesserix.yaml
└── prod/
    ├── apps/global/<service>.yaml
    ├── infrastructure/
    └── projects/tesserix.yaml
```

### ArgoCD App Template

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <service>
  namespace: argocd
spec:
  project: tesserix-{dev|prod}
  source:
    repoURL: https://github.com/tesserix/tesserix-k8s.git
    targetRevision: main
    path: charts/apps/<service>
    helm:
      valueFiles:
        - values.yaml
        - ../global-config.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: tesserix
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Gotchas & Common Pitfalls

### 1. @tesserix/web package auth
The `@tesserix/web` package is hosted on GitHub Packages. Always need `NODE_AUTH_TOKEN` set:
```bash
NODE_AUTH_TOKEN=$(gcloud secrets versions access latest --secret=prod-ghcr-token --project=tesseracthub-480811) npm install
```

### 2. Docker build secrets
Never put tokens in Dockerfile args. Use Docker build secrets:
```dockerfile
RUN --mount=type=secret,id=NODE_AUTH_TOKEN ...
```
In CI: `--secret id=NODE_AUTH_TOKEN,env=NODE_AUTH_TOKEN`

### 3. Istio sidecar port exclusions
Services that connect to NATS (4222), PostgreSQL (5432), or Redis (6379) need port exclusions in pod annotations. The `common.podAnnotations` helper adds these automatically.

### 4. ReadOnly root filesystem
Next.js apps need emptyDir volumes for `/tmp` and `/app/.next/cache` when `readOnlyRootFilesystem: true`.

### 5. GKE Metadata server
Pods using Workload Identity must exclude `169.254.169.254/32` from Istio proxy:
```yaml
traffic.sidecar.istio.io/excludeOutboundIPRanges: "169.254.169.254/32"
```

### 6. Knative deployment
Services deployed via Knative use `kubectl patch ksvc` with a timestamp annotation to trigger rollout — not `kubectl rollout restart`.

### 7. External Secrets refresh
ExternalSecrets refresh every 1 hour. For immediate secret rotation, delete the K8s secret and let ESO recreate it.

### 8. MongoDB ObjectId
MongoDB uses `_id` (ObjectId), not `id`. All frontend code must reference `post._id`, not `post.id`.

### 9. Image registries
- **GHCR** (`ghcr.io/tesserix/`) — primary for all services
- **GAR** (`asia-south1-docker.pkg.dev/tesseracthub-480811/`) — secondary for Cloud Run

### 10. Port conventions
| Service Type | Port |
|-------------|------|
| Go microservices | 8080-8099 |
| Next.js apps (local dev) | 3001-3200 |
| Next.js apps (Docker/GKE) | 3000 |

---

## Platform Architecture Quick Reference

- **Backend:** Go 1.26, Gin, GORM, PostgreSQL (microservices) / MongoDB (blog)
- **Frontend:** Next.js 16, React 19, TypeScript, Tailwind v4, @tesserix/web
- **Auth:** Keycloak + OpenFGA (marketplace) / Keycloak OIDC (blog)
- **Infra:** GKE, Istio, ArgoCD, Helm, KEDA, cert-manager
- **Messaging:** Google Pub/Sub
- **Caching:** Redis
- **Secrets:** GCP Secret Manager via External Secrets Operator
- **CI/CD:** GitHub Actions → GHCR → GKE/Knative (ArgoCD for Helm sync)
- **GCP Project:** tesseracthub-480811, Region: asia-south1
