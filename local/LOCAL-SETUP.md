# Tesserix Local Kubernetes — setup guide

Run the Tesserix apps on a **local kind cluster** (via
[`sandboxctl`](https://github.com/tesserix/sandboxctl)) so you can build,
deploy, and test changes end-to-end **before** pushing anything to GitHub or
GKE prod. Everything runs on your Mac behind stable `*.sandbox.app:8443` URLs.

> **Decoupled from prod by design.** Nothing here talks to the GKE prod
> cluster, GCP Secret Manager, or prod Postgres/Redis. Secrets are plain local
> Secrets (not ExternalSecrets), images are built locally, Workload Identity is
> off, and the GKE/auth/dashboard env values are neutralised in the
> `values-local.yaml` overlays. See [Decoupling guarantees](#decoupling-guarantees).

---

## 0. Bring the sandbox up (once) + bootstrap

**Step 1 — bring the kind sandbox up.** Slow/heavy; run it ONLY when the sandbox
isn't already up (first run ≈ 10 min):

```sh
sandboxctl up --with-cnpg --podman-disk 80 --podman-memory 12g
```

This stands up kind + Argo CD + Gitea + in-cluster registry (`localhost:5050`) +
Istio + a wildcard cert + the CloudNativePG operator. `sandboxctl creds` prints
URLs + admin passwords.

**Step 2 — bootstrap everything on top of it** (from the tesserix-k8s repo root):

```sh
make local-up
```

`local-up` is the POST-up bootstrap: it pushes the charts to the in-cluster
Gitea and applies the **app-of-apps** (`charts/apps/local-root`), which Argo CD
syncs in sync-wave order — `cnpg-operator → local-infra (shared CNPG + Redis +
NATS + Mongo) → products`. It does **not** re-run `sandboxctl up` (it preflight-
checks the cluster and tells you to run it if it's down). Re-run `make local-up`
anytime to re-push + re-sync.

`make local-doctor` reports what's up; `make local-status` shows app + datastore
health; `make local-down` wipes the sandbox.

> **Shared datastores.** Every product connects to ONE shared `local-infra`
> (Postgres `local-pg-rw.local-infra.svc`, Redis/NATS/Mongo likewise) via the
> reflected `local-infra-creds` Secret — no per-product DB. Reset one product's
> data with `make local-clean PRODUCT=devai`.

---

## 1. DevAI — two ways to deploy

Both flows read the same template: copy it and fill in the `REPLACEME_*` values
(plain text — `stringData` is base64-encoded for you). `k8s/secrets.yaml` is
gitignored.

```sh
cd devai
cp k8s/secrets.example.yaml k8s/secrets.yaml
$EDITOR k8s/secrets.yaml      # set at least one LLM key + a GitHub PAT
```

### Flow A — all-in-one chart (fastest; `sandboxctl deploy`)

Self-contained chart at `devai/k8s/chart/`: the API plus a bundled Postgres
(pgvector) and Redis. One command builds the image, applies the Secret, pushes
the chart to Gitea, creates the Argo app, and routes the URL:

```sh
cd devai
sandboxctl deploy            # autodiscovers k8s/chart + sandboxctl.yaml + k8s/secrets.yaml
# → https://devai.sandbox.app:8443
```

Uses only the top `devai-secrets` block of `secrets.example.yaml`.

### Flow B — per-chart, prod-faithful overlays (`helm` / Argo)

Deploys the real `tesserix-k8s/charts/apps/devai-*` charts with their
`values-local.yaml` overlays (api, sre, dashboard, sre-dashboard, auth-bff)
against the **shared `local-infra`** datastores (`make local-up` must have run
first). Mirrors prod topology. Uses the named Secrets in the lower half of
`secrets.example.yaml`.

The one-shot installer does the whole sequence (preflight shared-infra →
namespace → secrets → images → schema → charts):

```sh
tesserix-k8s/local/install-devai-local.sh   # run from the workspace root
```

It loads the DevAI schema into the shared `devai_db` (the local-infra CNPG
creates it empty):

```sh
kubectl -n devai create configmap devai-schema \
  --from-file=devai.sql=tesserix-k8s/charts/apps/db-schema-bootstrap/schemas/devai/devai_db/devai.sql
kubectl -n devai apply -f tesserix-k8s/local/devai/schema-bootstrap.job.yaml
kubectl -n devai wait --for=condition=complete job/devai-schema-bootstrap --timeout=120s
```

**Pick one flow per app** — don't run A and B for devai at the same time.

---

## 2. URLs & access

| Flow | Reach it via |
|---|---|
| A (sandboxctl) | `https://devai.sandbox.app:8443` (Istio-routed, auto) |
| B (helm/Argo)  | `kubectl -n devai port-forward svc/devai-api 8080:8080` (and `svc/devai-dashboard 3100:3100`) |

`sandboxctl status` / `sandboxctl validate` show health and HTTP codes.

---

## 3. Iterate (rebuild → redeploy)

```sh
# Flow A
cd devai && sandboxctl deploy            # rebuilds the image, re-syncs, restarts

# Flow B (one service)
docker build -t devai-api:local -f devai/Dockerfile devai
kind load docker-image devai-api:local
kubectl -n devai rollout restart deploy/devai-api
```

---

## 4. Reset local data

Reset just one product's slice of the shared datastores (drops+recreates its
Postgres DBs, flushes its Redis logical DB, drops its Mongo DB, purges its NATS
streams — other products untouched):

```sh
make local-clean PRODUCT=devai      # from the tesserix-k8s repo root
```

Full teardown: `make local-down` (= `sandboxctl down`).

---

## Decoupling guarantees

The local overlays are verified to never reach prod:

- **No ExternalSecrets / GCP SM** — plain local Secrets from `k8s/secrets.yaml`.
- **No Workload Identity** — `gcp.workloadIdentity.enabled=false`; the SA
  carries no `iam.gke.io/gcp-service-account` annotation.
- **GKE/auth/dashboard neutralised** — `devai-api/values-local.yaml` sets
  `DEVAI_GKE_PROJECT=""` (no GCP Secret Manager fetch to the prod project),
  `DEVAI_DASHBOARD_BASE_URL=http://localhost:8080`,
  `DEVAI_PREVIEW_DOMAIN=localhost`. `DEVAI_GKE_USE_IN_CLUSTER=true` resolves to
  the **local kind** apiserver via its in-cluster SA — never a prod kubeconfig.
- **Local images** — `:local` / `localhost:5050/*`, `pullPolicy: IfNotPresent`,
  no GAR/GHCR pull.
- **Local datastores** — the shared `local-infra` (CNPG `local-pg-rw.local-infra`,
  Redis/NATS/Mongo in `local-infra`), or (Flow A) the all-in-one chart's bundled
  datastores. No prod DB/Redis DNS.

**One intentional exception:** `devai-auth-bff` keeps
`DEVAI_BFF_GCP_PROJECT_ID=tesseracthub-480811`. This is **Google Identity
Platform** (a global, hosted Google auth service) used to *verify* ID tokens
against Google's public JWKS — it is **not** the GKE cluster and makes no
connection to prod infrastructure. auth-bff is optional locally; skip it unless
you're testing the real Google login flow.

## Auth on `*.sandbox.app` (auth-bff + GIP)

The BFF picks a GIP tenant by matching the request `Host`, so the overlay uses
the **sandbox.app** hostnames (`devai.sandbox.app`, `sre.sandbox.app`,
`aregistry.sandbox.app`, `kagent.sandbox.app`), a `.sandbox.app` session cookie,
and `Secure=true` (sandbox.app is TLS on :8443).

For login to actually work over sandbox.app, run once against your GCP project
(it adds `sandbox.app` as a GIP **Authorized domain** and creates **dedicated
local tenants** so prod pools are untouched):

```sh
gcloud auth login
PROJECT=tesseracthub-480811 tesserix-k8s/local/gip-local-setup.sh
# → prints DEVAI_BFF_ALM_TENANT_ID / SRE_TENANT_ID / GIP_WEB_API_KEY
#   to paste into devai/k8s/secrets.yaml (Secret devai-auth-bff-secrets)
```

Want auth fully isolated from prod? Point `PROJECT` at a **separate GCP project**
dedicated to local testing and run the script there — sandbox.app + tenants get
created in that project, and nothing in the prod project changes.

---

## Deploying any other Tesserix app locally

The pattern generalises. For any repo with a `Dockerfile` + a Helm chart:

1. Add `k8s/secrets.example.yaml` (plain Secret, `REPLACEME_*`) and a
   `values-local.yaml` overlay that disables ExternalSecrets/WI/KEDA/Istio and
   neutralises any prod URLs/projects.
2. `cp k8s/secrets.example.yaml k8s/secrets.yaml` and fill it in.
3. `cd <repo> && sandboxctl deploy` (autodiscovers chart + secrets + Dockerfile)
   → `https://<chart-name>.sandbox.app:8443`.

That's the whole loop — build/test on kind, then push to GitHub/GKE only once
it's green locally.
