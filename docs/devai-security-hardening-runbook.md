# DevAI Security Hardening + Dashboard Overhaul — Deploy Runbook

This runbook ships the changes from the DevAI review across three repos. **Read the
ordering carefully** — some changes are *behavior-neutral until you flip a flag*, and
flipping the auth flag **before the new images are live will cause a login/identity
outage**. Nothing here was deployed automatically; you run every build/sync step.

Repos touched: `devai` (Python + 2 Next.js dashboards + auth-bff Go), `agentic-registry`
(Go), `tesserix-k8s` (Helm charts + ArgoCD apps).

---

## TL;DR ordering

1. **Rotate secrets** (the live `devai/k8s/secrets.yaml` creds) + create the new BFF shared secret in GCP SM.
2. **Recover `devai-postgres`** (it is DOWN — disk full) — live op.
3. **Build & push images** (CI) for every changed component.
4. **Deploy WAVE 1** charts (all the hardening that's *dormant* — zero behavior change).
5. **Verify** WAVE 1 is healthy with the new images live.
6. **Deploy WAVE 2** — the deliberate auth enablement flip.
7. **Post-deploy verification** (read-only).

---

## 0. Pre-flight — rotate secrets (VERIFY-1) 🔴

`devai/k8s/secrets.yaml` (gitignored, never committed — **not** a git leak) holds **live**
credentials. Rotate them regardless of this deploy:

- Anthropic API key, GitHub fine-grained PAT, GitHub App `3310021` private key,
  webhook HMAC secret, Keycloak client secret, BFF session-encrypt key, GIP web key.

Rotate at the source, then update the matching GCP Secret Manager secrets (ESO re-syncs
within 1h, or delete the K8s Secret to force immediate re-pull). Then replace the on-disk
file with throwaway dev-scoped values or sops/age-encrypted content; keep only
`secrets.example.yaml` with `REPLACEME` placeholders.

**Create the new auth-bff shared secret** (needed by WAVE 2):

```bash
gcloud secrets create prod-devai-auth-bff-shared-secret \
  --project=tesseracthub-480811 --replication-policy=automatic
openssl rand -hex 32 | gcloud secrets versions add prod-devai-auth-bff-shared-secret \
  --project=tesseracthub-480811 --data-file=-
```

The `devai-auth-bff-secrets` ExternalSecret now references this key (`DEVAI_AUTH_BFF_SHARED_SECRET`).

---

## 1. Recover `devai-postgres` (DEP-1) 🔴 — live outage

`devai-postgres-1` is **CrashLoopBackOff** — CNPG status `Not enough disk space`. The 5Gi
WAL PVC filled because (a) GCS WAL archiving is failing and (b) `max_slot_wal_keep_size`
(10GB) exceeded `walStorageSize` (5Gi). ArgoCD wrongly shows it Healthy.

The chart fix (recurrence prevention) is already applied in
`charts/apps/devai-postgres/values.yaml` (slot keep-size lowered vs WAL size; see also the
new `prometheusrule.yaml`). The **live recovery is manual** (emergency exception to the
ArgoCD-only rule):

1. Confirm the WI SA `app-secrets-devai-prod` has `roles/storage.objectAdmin` on
   `gs://tesseract-prod-backups-in`, and the pod can reach the metadata server +
   `storage.googleapis.com` (Istio must exclude `169.254.169.254/32`).
2. Expand the WAL PVC (storageclass allows expansion) so the instance starts and drains
   the WAL backlog.
3. Deploy the chart values change so the slot/PVC mismatch can't recur.
4. Consider HA (`instances: >1`) so a single disk can't take the DB fully offline.
5. Check `agentregistry-postgres` for the same hidden-Healthy risk.

> Until the DB is back, devai-api is degraded regardless of the rest of this runbook.

---

## 2. Build & push images (CI) — code changes are inert until shipped

Per `devai/CLAUDE.md` (repo is currently public) just push to trigger CI; otherwise use the
public→build→private cycle. Build/push:

- `devai` (api), `devai-sre`, `devai-dashboard`, `devai-sre-dashboard`, `devai-runner`, `auth-bff`
- `agentic-registry`

**Do not** run builds/pushes via any tool on my behalf — these are yours. Wait for green CI.

---

## 3. WAVE 1 — dormant hardening (safe, zero behavior change)

Commit `tesserix-k8s` (and let ArgoCD sync) **without** the auth-flip values. Everything here
is either declarative hardening or gated behind a flag that still defaults to today's behavior:

- **Preview isolation (CHART-2/3):** `manifests/devai-previews/previews.yaml` now has a
  default-deny egress NetworkPolicy (DNS only, `169.254.169.254/32` + product CIDRs blocked),
  `automountServiceAccountToken: false`, restricted PSA, and a dedicated `devai-preview-runner` SA.
- **`devai-sre` ClusterRole (CHART-4):** cluster-wide `secrets` read **removed**.
- **agentic-istio DENY (CHART-5):** now covers `/v0/*`, `/v0.1/*`, `/mcp`, `/mcp/*`.
- **securityContext (CHART-6):** `allowPrivilegeEscalation:false`, `drop:[ALL]`, RuntimeDefault
  seccomp on all devai app containers; full pod+container on `devai-auth-bff`.
- **Image pinning (CHART-7/8/11):** devai-api/auth-bff/mcp-hub off `:latest`; registry-bootstrap
  hardened; base images pinnable by digest.
- **CPU-limit removal (CHART-9):** memory-only policy across the 6 flagged charts.
- **Dockerfiles (CHART-10):** dashboards use `npm ci` + lockfile + `.dockerignore`.
- **CI gates (CHART-12):** Trivy pinned + gating; `devai/.github/dependabot.yml` added.
- **Drift fixes (DEP-3/5/6/7/8):** agentgateway repinned `v1.2.1`→**`v1.0.1`** (the only published
  stable tag — `v1.2.1` never existed, which is why the app was stuck Unknown); route-sync kubectl
  image repinned off the removed `bitnami/kubectl`; fanzone-prediction-agent wait-for-postgres;
  ExternalSecret `ignoreDifferences` + Kargo interval normalization.

App code in WAVE 1 (already in the new images): all the SSRF/LFI/injection/IDOR/cleanup fixes are
either always-on safe fixes (e.g. registry mustache LFI, cross-tenant overwrite block, preview
ownership/reaper, redaction) or **flag-gated to today's behavior**.

> ⚠️ After `agentgateway` repins to `v1.0.1` and the control plane reconciles, re-check the
> **data plane** (DEP-4): it was crashlooping on an XDS `RBAC: access denied`. `1.0.1` is the only
> stable tag, so if the data-plane regression persists you'll need an upstream-fixed release.
> One-time orphan cleanup (DEP-7), live op:
> `kubectl delete cronjob,configmap,serviceaccount -n devai -l app.kubernetes.io/instance=agentic-registry-db-schema-bootstrap`

---

## 4. Verify WAVE 1

```bash
kubectl get applications -n argocd | grep -E 'devai|agentic|agentgateway'   # Synced/Healthy
kubectl get pods -n devai                                                    # no CrashLoop
kubectl get netpol -n devai-previews                                         # now NON-empty
kubectl get sa -n devai-previews                                             # devai-preview-runner present
```

Confirm the new image tags are live on devai-api / devai-sre / dashboards / auth-bff / agentic-registry.

---

## 5. WAVE 2 — the deliberate AUTH flip 🔒 (only after WAVE 1 is healthy)

This is the one ordering trap: flipping these **before** the WAVE-1 images are live breaks login,
because `identity._forward_trusted` now fails closed when a shared secret is configured but the
auth-bff isn't yet stamping `X-Auth-Bff-Secret`. With the new images live, the loop is closed.

Set in `tesserix-k8s` prod values, commit, sync:

- `devai-api` + `devai-sre`: `requireAuth: true` (→ `DEVAI_REQUIRE_AUTH=true`) and wire
  `DEVAI_AUTH_BFF_SHARED_SECRET` (now in the `devai-auth-bff-secrets` ExternalSecret).
- `devai-mcp-hub`: both flags stay **false** for now — see WAVE-3 below.
- `agentic-registry`: `AUTH_ANONYMOUS_ROLE=read` + `AUTH_TRUSTED_PROXY=true` (downgrades the
  anonymous=admin posture to read-only; the bootstrap/seed write path is unaffected — seeds call
  `store.Apply` directly, and the mesh DENY already restricts writes to the bootstrap SA).

Roll one service at a time and watch login + a known mutating call after each.

---

## 5a. WAVE 3 — the remaining flags (2026-08-23)

Wired into the charts and set in prod values:

- `devai-api` + `devai-sre`: `trustForwardedWithoutSecret: false`. `DEVAI_AUTH_BFF_SHARED_SECRET` is
  an `optional:` secret key, so an ExternalSecret outage empties it — and an empty secret means
  "trust `X-Forwarded-*` from anyone". With this set, that case fails closed instead. No effect while
  the secret is present, which is why it can ship without a staged roll.
- `devai-api`: `toolWorkspaceRoot: /tmp/devai-docs`. The document tools take their `file_path` from a
  regex over issue text, so an unconfined pod reads whatever an issue author names. Nothing in prod
  feeds them a legitimate local file; drop a file in that directory to ingest one deliberately.
- `devai-mcp-hub`: `DEVAI_MCP_HUB_SSRF_ENFORCE` is wired but **still false**. It could not ship as
  written: the guard resolved the endpoint host and rejected every private address, but every
  in-cluster MCP resolves to a private ClusterIP — enforcing would have dropped the whole federated
  surface. devai#284 fixes that (RFC-1918 exempt for a host an explicit suffix allowlisted;
  loopback, link-local and `169.254.169.254` still blocked), so flip this to `"true"` once a tag
  containing that merge is the running image. Flipping it against an older image breaks federation.

`DEVAI_MCP_HUB_REQUIRE_AUTH` stays **false**, deliberately. Nothing in the devai codebase dials the
Hub's `/mcp`; its callers are MCP clients configured out of band, and none of them is known to stamp
identity. Flipping it 401s every one of them at once. Before flipping: confirm each caller sends
`X-Forwarded-User` **plus** `X-Auth-Bff-Secret` (the Hub pod has no shared secret env of its own, so
wire one too), then flip and watch the Hub log for `rejecting unauthenticated request`. Until then the
mesh `AuthorizationPolicy` restricting the Hub to five devai SAs is the control that holds.

---

## 6. Post-deploy verification (VERIFY-2, read-only)

```bash
kubectl get authorizationpolicy -n devai -o yaml                 # devai-api restricted to dashboard/bff SA
kubectl get netpol -n devai-previews                             # non-empty
kubectl exec deploy/devai-api -n devai -- env | grep -E 'REQUIRE_AUTH|SHARED_SECRET'
kubectl auth can-i list secrets --as=system:serviceaccount:devai:devai-sre -A   # expect "no"
```

Spot-check: unauthenticated `POST /api/pipeline/trigger` → 401; login still works; a preview
pod has no SA token and cannot reach `169.254.169.254`.

---

## Deferred follow-ups (low severity — track, not blocking)

- `StageResult.ok/failed` contract + workflow consumption (the condition-key validation half is done).
- SRE sensitive **GET** reads gating (mutating SRE surface is already covered by the blanket `enforce_auth`).
- Per-preview short-lived GitHub App token (the org PAT is already scrubbed from the shared PVC).
- `digest.go` `ContentHash` marshal-error swallow (registry, cosmetic).
- Full `pytest` run in CI (local sandbox can't compile `grpcio`).
- Optional: middleware CSP nonce to drop `unsafe-inline` from `script-src` in both dashboards.
- `_CleanupStage` run-id-keyed orphan reconcile pass (the per-run delete + TTL reaper are wired).
