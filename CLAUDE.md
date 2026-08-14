# Claude Reference Guide — tesserix-k8s

Kubernetes/ArgoCD conventions for this repo.

Rules that apply more broadly live one level up and are **not** repeated here:

- **Git identity, commit messages, no-AI-references** → `~/.claude/CLAUDE.md`
- **Build/deploy boundary, CI public→private cycle, SQL schema location,
  `@tesserix/web` token, GCP constants, repo map** → workspace `CLAUDE.md`

## Cluster Access

```bash
export KUBECONFIG=~/.kube/gke-prod
```

Set this before any `kubectl` or `argocd` command.

---

## No Manual kubectl apply — ArgoCD Only

**Never** use `kubectl apply`, `create`, `patch`, `edit`, or `set` to deploy or
modify cluster resources. All changes go through ArgoCD:

1. Change the Helm chart, values, external-secret, or ArgoCD app definition here
2. Commit and push to `main`
3. ArgoCD auto-syncs, or trigger it:
   ```bash
   # No syncStrategy. `apply` means "kubectl apply, skip hooks", so a patch
   # carrying it reports "successfully synced (all tasks run)" while every
   # PreSync/Sync/PostSync hook is silently skipped — the controller logs
   # `skipHooks=true` and that is the only trace. Omitting syncStrategy
   # leaves it nil and hooks run. Clear any leftover `.operation` first:
   # a merge patch merges into it and `apply` survives from the last one.
   kubectl patch app <name> -n argocd --type merge \
     -p '{"operation":{"sync":{"revision":"HEAD"}}}'
   ```

**Why:** manual applies drift from Git, get reverted by self-heal, and are not
auditable. The only exception is read-only debugging (`kubectl logs`, `describe`,
`get`, `exec`).

**Where things live:**

| What | Path |
|---|---|
| Helm charts | `charts/apps/<service>/` |
| ArgoCD apps | `argocd/prod/apps/<project>/` (app-of-apps) |
| External Secrets | `external-secrets/prod/<namespace>/` |
| Istio config | `charts/thirdparty/istio-config/` |
| Namespace labels (e.g. `istio-injection`) | `istio-config` chart — never `kubectl label` |

---

## Branch Naming

```
feat/short-description
bugfix/short-description
hotfix/short-description
```

---

## CI/CD

### Workflow patterns

- **Next.js apps:** lint → Docker build → GHCR push → GKE/Knative deploy → Trivy.
  Build uses `--secret id=NODE_AUTH_TOKEN` for `@tesserix/web`. Deploy via
  `kubectl patch ksvc <service> -n <namespace>`. Images: `ghcr.io/tesserix/<service>:<tag>`.
- **Go services:** `go vet` → tests → Docker build → GHCR + GAR push → Cloud Run
  deploy → Trivy. Private modules via `GOPRIVATE=github.com/tesserix/*` and the
  `go-private-token` secret.

### Required GitHub secrets

| Secret | Purpose | Source |
|--------|---------|--------|
| `PKG_READ_TOKEN` | `@tesserix/*` npm packages | GCP `prod-ghcr-token` |
| `GITHUB_TOKEN` | GHCR push, PR ops | built-in |

### GCP Workload Identity (CI → GKE)

```
Provider: projects/849928263410/locations/global/workloadIdentityPools/github-pool/providers/github-provider
SA:       github-actions@tesseracthub-480811.iam.gserviceaccount.com
Cluster:  tesseract-prod-in-gke   Region: asia-south1
```

---

## GCP Secret Manager

Project `tesseracthub-480811`. Naming: `{env}-{service}-{secret-name}` —
e.g. `dev-blog-mongodb-uri`, `prod-ghcr-token`, `dev-auth-bff-session-secret`.

```bash
gcloud secrets list --project=tesseracthub-480811 --filter="name:<search>"
gcloud secrets versions access latest --secret=<name> --project=tesseracthub-480811
gcloud secrets create <name> --project=tesseracthub-480811 --replication-policy=automatic
echo -n "value" | gcloud secrets versions add <name> --project=tesseracthub-480811 --data-file=-
```

Key tokens: `prod-ghcr-token` / `prod-ghcr-username` (GHCR + npm),
`go-private-token` (private Go modules).

---

## Helm Charts

```
charts/apps/
├── common/                  # library chart — _helpers.tpl, _gcp-secrets.tpl
├── global-config.yaml       # dev shared config
├── global-config-prod.yaml  # prod overrides
└── <service>/
    ├── Chart.yaml           # must depend on common
    ├── values.yaml          # dev defaults
    ├── values-prod.yaml     # prod overrides
    └── templates/
```

New-service template checklist:

- [ ] `deployment.yaml` — health probes, security context, emptyDir volumes for `readOnlyRootFilesystem`
- [ ] `service.yaml` — ClusterIP
- [ ] `serviceaccount.yaml` — Workload Identity annotation
- [ ] `ingress.yaml` — Kong (dev) / Istio (prod)
- [ ] `externalsecret.yaml` — GCP Secret Manager
- [ ] `network-policy.yaml` — default deny + explicit allows
- [ ] `authorization-policy.yaml` — Istio RBAC
- [ ] `scaledobject.yaml` — KEDA (conditional)
- [ ] `pdb.yaml` — PodDisruptionBudget (prod only, conditional)

Helpers: `{{ include "common.labels" . }}`, `common.selectorLabels`,
`common.podAnnotations`.

---

## ArgoCD

### Application template

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <service>
  namespace: argocd
spec:
  # Must name an AppProject that ACTUALLY EXISTS (argocd/prod/projects/) or the
  # built-in `default`. There is no `tesserix-dev` / `tesserix-prod` project —
  # that name used to be documented here and cost a silent failure (PR #86).
  # Real ones: infrastructure, platform, homechef, fanzone, gameverse, guardix,
  # horoscope, identity, postiz, release, scrapper, social, stockpilot,
  # tesserix-blog, data, ai-database, default.
  project: infrastructure
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
      # NEVER write `prune: false`. It is the zero value for that bool, so the
      # API server drops the key on write; the app-of-apps then diffs git
      # (present) against live (absent) and the app is pinned OutOfSync
      # forever. Omit it — false is the default — and explain the intent in a
      # comment. 194 manifests had this and 24 apps could never converge.
```

### Adding an Application — three things, two of them silent

1. **Create the manifest** in the right `argocd/<env>/...` directory.
2. **Register it** in that directory's `kustomization.yaml` under `resources:`.
   These are Kustomize apps, not directory apps — an unlisted file is not an
   error, it is simply never built, and the app-of-apps keeps reporting `Synced`
   while your Application does not exist.
3. **Use a real `project:`** (see above).

Only step 1 is visible if you get it wrong. Steps 2 and 3 fail silently — no error
in `kubectl`, the UI, or the controller logs. The only symptom is the app never
appearing. `scripts/validate-argocd-apps.py` checks all three and runs in PR
validation.

---

## Reference Docs — read these first when the topic comes up

| Topic | Doc |
|---|---|
| **Which PostgreSQL cluster a new service should use** (answer: an existing one) | [`docs/postgres-cluster-policy.md`](docs/postgres-cluster-policy.md) |
| **Creating/modifying/debugging/migrating PostgreSQL** | [`docs/cnpg-migration-guide.md`](docs/cnpg-migration-guide.md) |
| **Auth — GIP tenants, auth-BFF wiring, admin claims** | [`docs/gip-migration-plan.md`](docs/gip-migration-plan.md) |
| **Keycloak decommission** — what was removed and what still needs cutting over | [`docs/keycloak-decommission-plan.md`](docs/keycloak-decommission-plan.md) |
| **HomeChef platform topology** — services, domains, infra, E2E | [`docs/homechef-platform.md`](docs/homechef-platform.md) |
| **Vector store / embeddings for AI agents** (Qdrant, `ai-database` namespace — and why there is no operator) | [`docs/qdrant-vector-db.md`](docs/qdrant-vector-db.md) |
| **Secret storage** — OpenBao, `openbao` namespace: auth roles, policies, ESO wiring, unseal and recovery | [`docs/openbao-secrets.md`](docs/openbao-secrets.md) |

### CloudNativePG (CNPG) quick facts

All products use CNPG instead of standalone StatefulSets.

**Do NOT create a new cluster.** A service that needs PostgreSQL gets a
database on an existing one — `global-postgres` for platform and product
services, `infra-postgres` for Temporal and SRE tooling. The per-product
`charts/apps/{product}-postgres/` clusters are grandfathered, not a template:
the estate reached ten clusters holding ~1.1GB against 928Gi provisioned,
most single-instance on Spot nodes and three with no backup. Full policy,
including how to add a database and the two traps that waste an afternoon:
[`docs/postgres-cluster-policy.md`](docs/postgres-cluster-policy.md).

- `bootstrap.postInitSQL` runs **once, at cluster creation** — adding a line
  does not create the database on a running cluster
- Poolers are **transaction-mode** PgBouncer; a driver that reuses prepared
  statements must use `-rw` directly, not the pooler
- 3-instance HA where it is affordable: 1 primary + 1 sync replica + 1 async
  replica (several existing clusters are single-instance; that is a gap, not
  the target)
- WAL archiving via Barman Cloud to `gs://tesseract-prod-backups-in/`
- Storage `standard-rwo-retain` (Retain reclaim policy); TLS 1.3 only, auto-managed
- Endpoints: `{product}-postgres-rw` / `-ro` / `-r` on 5432
- **NetworkPolicy:** `cnpg-system` MUST be in the ingress policy for any namespace
  hosting a CNPG cluster, or the operator can't reach pods on port 8000 and
  replicas are never created. See `charts/thirdparty/istio-config/templates/network-policies.yaml`.
- Operator lives in `cnpg-system` (v1.24.1)

### Auth quick facts

Keycloak is decommissioned — there is no `identity-customer` / `identity-internal`
namespace, chart, or realm. All auth is Google Identity Platform, one tenant per
product, issuer `https://securetoken.google.com/tesseracthub-480811`.

The reference chart for the shared `ghcr.io/tesseract-nexus/global-services/auth-bff`
image is `charts/apps/devai-auth-bff/` — **not** `mark8ly-auth-bff`, which is a
different image with its own database and OpenFGA.

Admin access is the `admin: true` custom claim, granted by `gip-admin-claims`.

---

## Gotchas

1. **`@tesserix/web` auth** — needs `NODE_AUTH_TOKEN` from `prod-ghcr-token`.
2. **Docker build secrets** — never tokens in build args; use
   `RUN --mount=type=secret,id=NODE_AUTH_TOKEN` and `--secret id=NODE_AUTH_TOKEN,env=NODE_AUTH_TOKEN`.
3. **Istio sidecar port exclusions** — services hitting NATS (4222), PostgreSQL
   (5432), or Redis (6379) need exclusions; `common.podAnnotations` adds them.
4. **ReadOnly root filesystem** — Next.js needs emptyDir for `/tmp` and
   `/app/.next/cache`.
5. **GKE metadata server** — Workload Identity pods must exclude
   `169.254.169.254/32` via `traffic.sidecar.istio.io/excludeOutboundIPRanges`.
6. **Knative deploys** — `kubectl patch ksvc` with a timestamp annotation, not
   `kubectl rollout restart`.
7. **External Secrets refresh** — hourly. For immediate rotation, delete the K8s
   secret and let ESO recreate it.
8. **MongoDB** — uses `_id` (ObjectId), not `id`. Frontend must use `post._id`.
9. **Image registries** — GHCR `ghcr.io/tesserix/` is primary; GAR
   `asia-south1-docker.pkg.dev/tesseracthub-480811/` is secondary for Cloud Run.
10. **Ports** — Go services 8080–8099; Next.js local 3001–3200, in-container 3000.
11. **`RespectIgnoreDifferences=true` + SSA + jq ignores into a list** — the
    normalisation can strip the whole list from the apply: sync reports
    Succeeded, the resource's `generation` never moves, and the change silently
    never lands. Bit dwellm8-postgres via the argocd-cm jq ignores into
    `spec.managed.roles[]`. If a synced change is not taking effect, check
    `generation` and the `managedFields` timestamps before anything else.
12. **Memory-only resources — never set `cpu` requests or limits.** For an
    upstream chart, *omitting* cpu is not enough: Helm deep-merges, so a
    memory-only `resources:` block still inherits the chart's cpu default.
    Write `cpu: null` explicitly. Two knock-on rules: a cpu-target HPA or a
    KEDA `cpu` trigger cannot work without a request (metric reads
    `<unknown>`; KEDA's webhook rejects it outright), so scale on memory; and
    a VPA must use `controlledResources: ["memory"]` or it re-injects cpu.
13. **Never ignore all of `/status` in `ignoreResourceUpdates`.** A pod going
    ready is a status-only event, so the controller drops it, its cached copy
    of the workload never changes, and cached health freezes until an
    unrelated non-status write or the 12h cache resync. Anything gated on that
    health — a sync waiting on a wave, a hook Job — waits with it, while
    `kubectl` shows the workload perfectly healthy. Ignore heartbeat fields
    (`lastTransitionTime`, `observedGeneration`) instead. Per-kind rules are
    additive with `.all`, so a kind cannot opt back out.

---

## Architecture Quick Reference

- **Backend:** Go 1.26, Gin, GORM, PostgreSQL (microservices) / MongoDB (blog)
- **Frontend:** Next.js 16, React 19, TypeScript, Tailwind v4, `@tesserix/web`
- **Auth:** Google Identity Platform + OpenFGA (marketplace) / GIP (blog)
- **Infra:** GKE, Istio, ArgoCD, Helm, KEDA, cert-manager
- **Messaging:** Google Pub/Sub · **Caching:** Redis
- **Secrets:** GCP Secret Manager via External Secrets Operator
- **CI/CD:** GitHub Actions → GHCR → GKE/Knative (ArgoCD for Helm sync)
