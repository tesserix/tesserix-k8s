# local-infra — shared sandbox datastores

One Helm release that gives the local sandbox **all** the shared infrastructure
every product connects to, so you don't run a Postgres/Redis/NATS/Mongo per
product. **Local/sandbox only** — prod uses per-product CNPG + datastores.

## What it provides

| Component | Stable endpoint (in-cluster DNS) | Notes |
|-----------|----------------------------------|-------|
| **CNPG Postgres** | `local-pg-rw.local-infra.svc.cluster.local:5432` | 12Gi; one role + DB(s) per product (auto-created) |
| **Redis** | `redis.local-infra.svc.cluster.local:6379` | one logical DB index per product |
| **NATS (JetStream)** | `nats.local-infra.svc.cluster.local:4222` | stream prefix per product |
| **MongoDB** | `mongodb.local-infra.svc.cluster.local:27017` | one DB per product that needs it (e.g. mark8ly otto) |

CNPG operator comes from `sandboxctl up --with-cnpg`. Everything else is in this
chart. Storage is a real PVC by default; set `persistence: emptyDir` for a
cluster with no StorageClass.

## Auto-connect (no per-deploy wiring)

One Secret, **`local-infra-creds`**, holds the shared password (Postgres = Redis
= Mongo, all the same throwaway local value) plus host hints. It is annotated for
**reflector** (bundled with sandboxctl), which mirrors it into every product
namespace (`agentic-registry`, `devai`, `homechef`, `marketplace`, `fanzone`).
Each product's `values-local.yaml` points its DB/Redis/NATS/Mongo env at the
endpoints above and reads the password from `local-infra-creds`. Deploy
`local-infra` first; products then come up already connected.

## Per-product data cleanup

Because the stores are shared, switch between products by resetting just one
product's slice:

```sh
./clean-product.sh --list          # products + their slices
./clean-product.sh devai           # drop+recreate devai_db, flush its Redis DB, purge its NATS streams
```

Each product gets a **suspended** `local-infra-clean-<product>` CronJob; the
script triggers it as a one-off Job. Other products are untouched. There is no
"wipe everything" here on purpose — that's `sandboxctl down`.

## Deploy

```sh
sandboxctl up --with-cnpg --podman-disk 80 --podman-memory 12g
sandboxctl deploy --chart ../tesserix-k8s/charts/apps/local-infra --name local-infra --no-build
```

Then deploy products (each `SETUP_LOCAL.md` covers this).
