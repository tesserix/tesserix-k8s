# Topology-Aware Routing Runbook

## Goal
Reduce inter-zone egress on the `tesseract-prod-in-gke` regional cluster
(currently ~130 GB/day → ~55 AUD/mo). Each cross-zone Service call costs
egress; routing same-zone first eliminates that hop.

## How Kubernetes topology-aware routing works
- EndpointSlices include a `hints.forZones` field per endpoint.
- `kube-proxy` prefers endpoints whose `forZones` contains the current node's zone.
- Two ways to enable:
  1. Annotation `service.kubernetes.io/topology-aware-hints: auto` — controller fills hints based on endpoint distribution and CPU capacity per zone.
  2. `spec.internalTrafficPolicy: Local` — strict same-node routing; falls back to nothing if no local endpoint (high blast radius, only use when caller exists on every node).

## Prerequisites
- Topology hints engage when `endpoints ≥ ~3 × zones` (≥9 for a 3-zone cluster) AND endpoints are reasonably balanced. Below that, kube-proxy will fall back to default behaviour silently.

## Target services (verified to have multi-zone endpoints)

| Service | Endpoints | Why high-traffic | Action |
|---|---|---|---|
| `nats/nats` | 3 in 3 zones | Message bus across all apps | annotate |
| `nats/nats-ilb` | 3 in 3 zones | Internal LB → NATS | annotate |
| `monitoring/prometheus-prometheus-node-exporter` | 3 in 3 zones | DaemonSet scraped continuously | annotate |
| `istio-egress/istio-egressgateway` | 3 in 3 zones | All egress | annotate |
| `homechef/homechef-postgres-r` | 3 in 2 zones | PG read replica | annotate (validate first) |
| `stockpilot/stockpilot-api` | 3 in 3 zones | API service | annotate |
| `tesserix/tesserix-blog` | 3 in 3 zones | Blog frontend | annotate |

## Apply (per-service, reversible)

```sh
for svc in \
  nats/nats \
  nats/nats-ilb \
  monitoring/prometheus-prometheus-node-exporter \
  istio-egress/istio-egressgateway \
  stockpilot/stockpilot-api \
  tesserix/tesserix-blog; do
  ns=${svc%/*}; name=${svc#*/}
  kubectl annotate svc -n "$ns" "$name" \
    service.kubernetes.io/topology-aware-hints=auto --overwrite
done
```

**Validate** after each apply — confirm hints are filling in:

```sh
kubectl get endpointslice -A -o json \
  | jq -r '.items[] | select(.metadata.labels."kubernetes.io/service-name"=="nats")
           | .endpoints[] | {addr: .addresses[0], zone, hints}'
```

If `hints.forZones` is null after 60s, the controller didn't engage — typically
because endpoints are unbalanced or below threshold. Re-evaluate.

## Rollback
```sh
kubectl annotate svc -n <ns> <svc> service.kubernetes.io/topology-aware-hints-
```

## What this WILL NOT fix
The majority of your inter-zone traffic is from single-replica deployments
(one pod, one zone) being called from clients in other zones. Topology hints
cannot help those flows — they need either:

1. **Scale to ≥3 replicas with topology spread**, e.g.:
   ```yaml
   topologySpreadConstraints:
   - maxSkew: 1
     topologyKey: topology.kubernetes.io/zone
     whenUnsatisfiable: DoNotSchedule
     labelSelector:
       matchLabels: { app: <name> }
   ```
2. **Pod affinity to co-locate caller + callee** in the same zone (only when latency-coupled).

## Long-term structural fix
With only 3 nodes (1 per zone), the regional cluster topology is
working against you. Two architectural options:

- **Add a second node per zone (6 nodes total)** — gives most services
  enough replicas for topology hints to engage; ~$80 AUD/mo extra compute,
  ~$30 saved on egress, net wash but much better resilience.
- **Switch to zonal cluster (single zone)** — eliminates inter-zone
  egress entirely AND drops the $80/mo regional GKE fee, but loses
  zone-failure HA. Not recommended given Postgres + payments workloads.

Apply the per-service annotations above first; revisit topology after
2 weeks of billing data.
