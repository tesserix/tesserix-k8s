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
| Image | `nats:alpine`, `pullPolicy: Always` | `nats:2.10-alpine`, `IfNotPresent` | A pod restart can no longer silently jump NATS major/minor on a stateful Raft node. |
| PodDisruptionBudget | flag set but **no template** (no-op) | real `PDB minAvailable: 2` | Preserves Raft majority during node drains/upgrades. |
| Anti-affinity | zone spread *preferred* only | *required* one-pod-per-node + *preferred* zone spread | A single node loss can take down at most one replica. |
| Liveness probe | `/healthz?js-enabled-only=true` | `/healthz` (basic) | A node catching up on JetStream is no longer restarted mid-recovery. |
| Startup probe | none | `/healthz`, up to ~5m | Long JS store recovery on boot can't trip liveness. |
| Graceful shutdown | none | `lame_duck_*` + `terminationGracePeriodSeconds: 60` | Clients drain/reconnect on rolling restarts. |
| Slow consumers | none | `write_deadline: 10s` | Server sheds a stuck consumer instead of back-pressuring. |
| Capacity | `max_connections: 1000`, mem 512Mi/2Gi | `65536`, mem 1Gi/4Gi | Headroom for many products fanning in at scale. |
| JetStream disk | 12Gi | 20Gi (`max_file_store` + PVC) | More retention/headroom for the shared bus. |
| Cluster rejoin | default | `connect_retries: 120` | Resilient route re-establishment after a blip. |
| Metrics | none | Prometheus exporter sidecar + ServiceMonitor (wired, **off** by default) | Observability; enable after confirming the exporter tag. |

Memory-only resources (platform rule: no CPU requests/limits in these charts).

## Deploy

GitOps only — do not `kubectl apply`. **This change bumps JetStream disk 12Gi →
20Gi.** StatefulSet `volumeClaimTemplates` are immutable, so the size can't be
updated in place — every other change (image, probes, affinity, grace period) is
a template mutation that would apply via a normal rolling update, but the disk
bump needs the expand + orphan-recreate below. Doing them together lands the
whole PR in one clean pass with **no downtime** (pods keep serving throughout).

1. Merge this branch to `main` (or sync from the branch in a maintenance window).
2. Confirm the storage class allows online expansion:
   ```bash
   kubectl get storageclass standard-rwo-retain -o jsonpath='{.allowVolumeExpansion}'   # true
   ```
3. Expand the three PVCs to 20Gi (online; data preserved):
   ```bash
   for i in 0 1 2; do
     kubectl -n nats patch pvc data-nats-$i --type merge \
       -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
   done
   kubectl -n nats get pvc     # wait for each to reach 20Gi / FileSystemResizePending to clear
   ```
4. Orphan-delete the StatefulSet so ArgoCD can recreate it at the new size
   (the pods keep running — only the STS object is removed):
   ```bash
   kubectl -n nats delete statefulset nats --cascade=orphan
   ```
5. Sync the `nats` ArgoCD app. It **creates** the STS fresh (no immutable-field
   conflict) at 20Gi with all the hardening, adopts the running pods, then rolls
   them one at a time. The PDB (`minAvailable: 2`) holds quorum throughout.
6. Verify:
   ```bash
   kubectl -n nats get pods -w
   kubectl -n nats exec -it nats-0 -- nats server list       # 3 servers, JS healthy
   kubectl -n nats exec -it nats-0 -- nats stream report      # streams R3, no "no quorum"
   kubectl -n nats exec -it nats-0 -- nats server report jetstream   # per-server store 20Gi
   ```

> If step 4 is skipped, ArgoCD sync will fail on the STS (immutable
> volumeClaimTemplates) and **none** of the STS changes apply until the STS is
> orphan-deleted. Steps 3–4 are the required unlock for the disk bump.

## Future storage changes

Same procedure as above (expand PVCs → orphan-delete STS → sync), substituting
the target size. `fileStore.size` and `persistence.size` must always move
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
