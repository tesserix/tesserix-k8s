# NATS / JetStream — production hardening

Scope of this change: make the **single-region** shared NATS cluster
prod-ready — HA across node/zone failure, able to absorb high event throughput,
JetStream enabled and durable. Superclusters/gateways are **not** used: they are
a multi-region tool and only become relevant if a second GKE region is added
(see "Multi-region roadmap" below).

Config lives in `charts/thirdparty/nats/`. Prod values are consolidated into
`values-prod.yaml` (the ArgoCD app now references it via `helm.valueFiles`
instead of an inline block that had drifted).

## What changed

| Area | Before | After | Why |
|------|--------|-------|-----|
| Image | `nats:alpine`, `pullPolicy: Always` | `nats:2.14-alpine`, `IfNotPresent` | A pod restart can no longer silently jump NATS major/minor on a stateful Raft node. |
| PodDisruptionBudget | flag set but **no template** (no-op) | real `PDB minAvailable: 2` | Preserves Raft majority during node drains/upgrades. |
| Anti-affinity | zone spread *preferred* only | *required* one-pod-per-node + *preferred* zone spread | A single node loss can take down at most one replica. |
| Liveness probe | `/healthz?js-enabled-only=true` | `/healthz` (basic) | A node catching up on JetStream is no longer restarted mid-recovery. |
| Startup probe | none | `/healthz`, up to ~5m | Long JS store recovery on boot can't trip liveness. |
| Graceful shutdown | none | `lame_duck_*` + `terminationGracePeriodSeconds: 60` | Clients drain/reconnect on rolling restarts. |
| Slow consumers | none | `write_deadline: 10s` | Server sheds a stuck consumer instead of back-pressuring. |
| Capacity | `max_connections: 1000`, mem 512Mi/2Gi | `65536`, mem 1Gi/4Gi | Headroom for many products fanning in at scale. |
| JetStream disk | 12Gi | 12Gi (unchanged) | Growing it is a separate manual run-book, see below. |
| Cluster rejoin | default | `connect_retries: 120` | Resilient route re-establishment after a blip. |
| Metrics | none | Prometheus exporter sidecar + ServiceMonitor (wired, **off** by default) | Observability; enable after confirming the exporter tag. |

Memory-only resources (platform rule: no CPU requests/limits in these charts).

## Deploy

GitOps only — do not `kubectl apply`. Every change here (image pin, probes,
affinity, grace period, PDB, config) is a template mutation that ArgoCD applies
as a normal rolling update with no downtime, so merging to `main` is the whole
deployment. The PVC size is deliberately left at the live 12Gi so the
StatefulSet's immutable `volumeClaimTemplates` do not block the sync.

Verify after the sync:

```bash
kubectl -n nats rollout status sts/nats
kubectl -n nats exec -it nats-0 -- nats server list        # 3 servers, JS healthy
kubectl -n nats exec -it nats-0 -- nats stream report      # streams R3, no "no quorum"
```

## Future storage changes

Growing the JetStream disk needs three manual steps, because
`volumeClaimTemplates` is immutable — expand the PVCs online, orphan-delete the
StatefulSet so ArgoCD can recreate it, then sync:

```bash
kubectl get storageclass standard-rwo-retain -o jsonpath='{.allowVolumeExpansion}'
for i in 0 1 2; do
  kubectl -n nats patch pvc data-nats-$i --type merge \
    -p '{"spec":{"resources":{"requests":{"storage":"<size>"}}}}'
done
kubectl -n nats delete sts nats --cascade=orphan   # pods keep serving
```

Then raise the size in `values-prod.yaml` and let ArgoCD recreate the
StatefulSet; it adopts the running pods and rolls them one at a time. `fileStore.size` and `persistence.size` must always move
together — a `max_file_store` larger than the disk lets JetStream fill the
volume. Capacity = event rate × retention, and the app streams are bounded
(`max-age`/`max-bytes`), so raise this only for longer retention or more headroom.

## Still open (tracked separately — not in this change)

These are the remaining prod-readiness items. The first two are **breaking**
(every consumer needs credentials/TLS), so they need a coordinated rollout, not
a one-shot flip on a bus ~30 services connect to anonymously today:

- **P0 — multi-tenant accounts + `$SYS` system account.** Today every product
  shares one anonymous account, so any pod can read/delete any other product's
  subjects and streams and exhaust JetStream. Give each product a NATS account
  with its own users (creds via ESO/GCP Secret Manager) and per-account
  JetStream limits (`max_file_store`/`max_streams`/`max_consumers`) to stop
  noisy-neighbour starvation.
- **P1 — TLS.** Istio mTLS is DISABLED for 4222 (JetStream needs the sidecar
  bypass) and there is no native NATS TLS, so inter-pod traffic is plaintext.
  Add native NATS server TLS.
- **P1 — stream ownership.** The `streams-init-job` pre-creates a *marketplace*
  stream set while `homechef-api` (and fanzone) create their own at boot — two
  regimes in one flat account. Accounts (P0) dissolve the collision; until then,
  keep subject namespaces disjoint per product.
- **P2 — backups.** Single region = single failure domain. Add periodic
  JetStream stream snapshots to GCS as the DR substitute for a second region.

## Multi-region roadmap (only if a 2nd region is added)

If geo-DR / a second GKE region becomes a requirement, *then* the supercluster
pattern applies: run an independent NATS cluster per region and join them with
**gateways** (full-mesh between clusters, interest-only propagation), and use
JetStream **stream mirrors/sources** for cross-region replication. Doing this
before the P0 account work would just replicate an un-tenanted, unauthenticated
cluster across regions — fix tenancy first.
