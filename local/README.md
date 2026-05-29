# tesserix-k8s/local

Local-kind (sandboxctl) deployment hub for the Tesserix apps. Everything here
runs on your Mac and is **decoupled from GKE prod** — use it to build and test
changes before pushing to GitHub / GKE.

**Start here → [LOCAL-SETUP.md](./LOCAL-SETUP.md)** — the full setup guide
(platform bring-up, the two DevAI deploy flows, URLs, reset, troubleshooting,
and how to add any other app).

## Shared local infrastructure (start here)

All products share ONE set of local datastores — **`charts/apps/local-infra`**
(CNPG Postgres 12Gi + Redis + NATS + MongoDB), ordered by the app-of-apps
**`charts/apps/local-root`**. Deploy it first; every product auto-connects via
the reflected `local-infra-creds` Secret + stable DNS
(`local-pg-rw.local-infra.svc`, `redis.local-infra.svc`, …). Reset one product's
data with `charts/apps/local-infra/clean-product.sh <product>`.

```sh
# Bring the kind sandbox up ONCE (slow/heavy — only when it isn't already up):
sandboxctl up --with-cnpg --podman-disk 80 --podman-memory 12g

# Then the post-up bootstrap, from the tesserix-k8s repo root (idempotent, fast):
make local-up
#   = push charts to the kind Gitea + apply the app-of-apps
#     (cnpg-operator -> local-infra -> products). Does NOT re-run 'sandboxctl up'.
# Doctor / status:  make local-doctor   |   make local-status
# Reset one product: make local-clean PRODUCT=devai
# Teardown:          make local-down
```

## Contents

| Path | What it is |
|---|---|
| `LOCAL-SETUP.md` | The canonical local-setup guide (any tesserix dev). |
| `install-devai-local.sh` | Idempotent installer for the per-chart DevAI flow (uses shared local-infra). |
| `gip-local-setup.sh` | Registers `sandbox.app` + dedicated local GIP tenants for auth-bff login. |
| `devai/schema-bootstrap.job.yaml` | Loads the DevAI schema into the shared `devai_db`. |

## How it relates to prod

- **Prod** lives under `argocd/prod/` + `charts/apps/` + `external-secrets/prod/`
  (ArgoCD + per-product CNPG + External Secrets + Istio on GKE).
- **Local** reuses the same `charts/apps/*` charts via their `values-local.yaml`
  overlays, with plain local Secrets and the SHARED `local-infra` datastores.
  The overlays never change prod behaviour — they only flip values that already
  exist. Prod is **not** affected by anything under `local/`.
