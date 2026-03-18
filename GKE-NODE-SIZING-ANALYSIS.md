# GKE Node Pool Sizing & Spot vs On-Demand Analysis

**Cluster:** `tesseract-prod-in-gke` | **Region:** asia-south1 (3 zones)
**Date:** March 3, 2026

---

## 1. Current State

### Cluster Config (from Terraform)
| Setting | Value |
|---|---|
| Machine Type | `e2-standard-16` (16 vCPU, 64 GB) |
| Node Pool | `optimized` (single pool) |
| Spot Instances | **Already enabled** (`spot = true`) |
| Autoscaling | totalMin=1, totalMax=5 |
| Current Nodes | 3 (one per zone) |
| Location Policy | `ANY` |

### Node Allocatable Resources (per node)
| Resource | Allocatable | Capacity |
|---|---|---|
| CPU | 15,890m (~15.9 vCPU) | 16 vCPU |
| Memory | ~58.6 Gi | ~64 Gi |
| Max Pods | 110 | — |

### Actual Resource Usage vs Requests vs Limits

| Metric | **Actual Usage** | **Requests** | **Limits** | Cluster Allocatable (3 nodes) |
|---|---|---|---|---|
| CPU | **6.4 vCPU (13%)** | 27.3 vCPU (57%) | 123.0 vCPU | 47.7 vCPU |
| Memory | **33.2 Gi (19%)** | 50.1 Gi (29%) | 165.8 Gi | 175.8 Gi |

### Per-Node Resource Distribution

| Node (Zone) | Pods | CPU Requests | Mem Requests | CPU Used | Mem Used |
|---|---|---|---|---|---|
| south1-b | 66 | 11,868m | 22,510 Mi | 1,035m (6%) | 11,286 Mi (19%) |
| south1-c | 83 | 11,829m | 22,599 Mi | 4,440m (27%) | 17,321 Mi (29%) |
| south1-a | 33 | 5,038m | 9,613 Mi | 961m (6%) | 4,615 Mi (7%) |

### Current Monthly Cost (SPOT pricing)

| Component | Calculation | USD/mo | AUD/mo |
|---|---|---|---|
| 3x e2-standard-16 SPOT | 3 x ~$119/mo | ~$357 | ~$553 |
| GKE Standard fee | $0.10/hr x 730 | ~$73 | ~$113 |
| **Total GKE Compute** | | **~$430** | **~$666** |

> **Note:** Original estimate of ~$1,800 AUD/mo assumed on-demand pricing. Actual cost is ~$666 AUD/mo because spot is already enabled.

---

## 2. StatefulSets & Internal Load Balancers

### 16 StatefulSets Running

| Namespace | StatefulSet | PVC Size | Disk Type | Zone |
|---|---|---|---|---|
| postgresql-fanzone | postgresql-0 | 650 Gi | pd-balanced | south1-c |
| postgresql-marketplace | postgresql-0 | 650 Gi | pd-balanced | south1-a |
| postgresql-homechef | postgresql-0 | 650 Gi | pd-balanced | south1-b |
| postgresql-global | postgresql-0 | 50 Gi | pd-balanced | south1-b |
| postgresql-hms | postgresql-0 | 60 Gi | pd-balanced | south1-b |
| postgresql-bookkeeping | postgresql-0 | 30 Gi | pd-balanced | south1-c |
| mongodb-fanzone | mongodb-0 | 350 Gi | premium-rwo | south1-a |
| nats-0 | nats | 12 Gi | standard-rwo | south1-a |
| nats-1 | nats | 12 Gi | standard-rwo | south1-c |
| nats-2 | nats | 12 Gi | standard-rwo | south1-b |
| redis-fanzone | redis-0 | 8 Gi | standard-rwo | south1-a |
| redis-marketplace | redis-0 | 16 Gi | standard-rwo | south1-a |
| redis-homechef | redis-0 | 4 Gi | standard-rwo | south1-a |
| redis-global | redis-0 | 8 Gi | standard-rwo | south1-b |
| redis-hms | redis-0 | 8 Gi | standard-rwo | south1-c |
| identity-customer redis | redis-master-0 | 2 Gi | premium-rwo | south1-b |
| identity-internal redis | redis-master-0 | 1 Gi | premium-rwo | south1-a |

**PVCs are spread across ALL 3 zones — this means we MUST have nodes in all 3 zones for StatefulSets to schedule.**

### 11 Internal Load Balancers (ILBs)

| Service | ILB IP | Used By |
|---|---|---|
| postgresql-fanzone/postgresql-ilb | 10.10.0.34 | Cloud Run (via VPC connector) |
| postgresql-global/postgresql-ilb | 10.10.0.35 | Cloud Run |
| nats/nats-ilb | 10.10.0.36 | Cloud Run |
| mongodb-fanzone/mongodb-fanzone-ilb | 10.10.0.37 | Cloud Run |
| redis-fanzone/redis-ilb | 10.10.0.38 | Cloud Run |
| redis-marketplace/redis-ilb | 10.10.0.39 | Cloud Run |
| postgresql-marketplace/postgresql-ilb | 10.10.0.40 | Cloud Run |
| postgresql-homechef/postgresql-ilb | 10.10.0.41 | Cloud Run |
| redis-homechef/redis-ilb | 10.10.0.42 | Cloud Run |
| istio-ingress/istio-ingressgateway-internal | 10.10.0.50 | Cloudflare tunnels |

### Key Insight: ILB IPs Are STABLE

**The ILB IP addresses (10.10.0.x) NEVER change when nodes or pods move.**

ILBs are GCP-managed forwarding rules. When a StatefulSet pod gets evicted (spot preemption) and reschedules to a different node:
1. The ILB IP stays exactly the same (10.10.0.34, etc.)
2. GCP's health check detects the pod moved to a new backend
3. Traffic automatically routes to the new pod location
4. Cloud Run services reconnect to the same ILB IP — no config changes needed

**What DOES happen during spot preemption:**
- The StatefulSet pod gets 30-second termination notice
- Pod shuts down gracefully (PostgreSQL flushes WAL)
- Pod reschedules on a node in the SAME zone (PVC is zone-locked)
- If a node exists in that zone → **30-90 seconds downtime**
- If NO node in that zone → autoscaler creates one → **2-5 minutes downtime**
- ILB reconnects automatically — **no manual intervention needed**

---

## 3. Sizing Options

### Why 3 Zones Are Required

PVCs are distributed across all 3 zones:
- **south1-a:** postgresql-marketplace, mongodb-fanzone, nats-0, redis-fanzone, redis-marketplace, redis-homechef, identity-internal-redis
- **south1-b:** postgresql-homechef, postgresql-global, postgresql-hms, nats-2, redis-global, identity-customer-redis
- **south1-c:** postgresql-fanzone, postgresql-bookkeeping, nats-1, redis-hms

Since PVCs (zonal disks) can only be mounted by pods on nodes in the SAME zone, **we must have at least 1 node per zone = 3 nodes minimum**.

### Machine Type Options

| Machine | vCPU | RAM | Allocatable CPU | Allocatable Mem | Spot $/mo | On-Demand $/mo | 1yr CUD $/mo |
|---|---|---|---|---|---|---|---|
| e2-standard-4 | 4 | 16 Gi | ~3.9 | ~14.2 Gi | ~$30 | ~$99 | ~$63 |
| e2-standard-8 | 8 | 32 Gi | ~7.9 | ~29.3 Gi | ~$59 | ~$198 | ~$125 |
| e2-standard-16 | 16 | 64 Gi | ~15.9 | ~58.6 Gi | ~$119 | ~$396 | ~$250 |

### Fitting Constraints

**Most loaded node (south1-b or south1-c) has ~12 vCPU in requests.**

| Machine Type | Min Nodes | Can fit 12 vCPU/node? | Total Allocatable | Fits 27.3 vCPU? |
|---|---|---|---|---|
| e2-standard-4 | 3 | NO (3.9 alloc) | 11.7 vCPU | NO — need 8+ nodes |
| e2-standard-8 | 3 | NO (7.9 alloc) | 23.7 vCPU | NO — need 4-5 nodes |
| e2-standard-8 | 4 | Redistribute | 31.6 vCPU | YES (with rebalancing) |
| e2-standard-16 | 2 | YES (15.9 alloc) | 31.8 vCPU | YES — but need 3 for zones |
| **e2-standard-16** | **3** | **YES** | **47.7 vCPU** | **YES (current)** |

---

## 4. Option Comparison

### Option A: Stay e2-standard-16 Spot (Current) — No change

| Metric | Value |
|---|---|
| Nodes | 3 x e2-standard-16 spot |
| Cost | **$357 USD / ~$553 AUD per month** |
| Overhead | 75% idle CPU, 71% idle memory |
| Spot risk | Preemption every ~24hrs, 30-90s DB downtime |
| Pros | Simple, already working |
| Cons | Massively overpowered |

### Option B: Downsize to e2-standard-8 Spot — 4 nodes

Need 4 nodes to fit 27.3 vCPU requests (3 nodes x 7.9 = 23.7, not enough).

| Metric | Value |
|---|---|
| Nodes | 4 x e2-standard-8 spot (totalMin=3, totalMax=6) |
| Cost | **$236 USD / ~$366 AUD per month** |
| Savings | **$121 USD / ~$187 AUD per month (34%)** |
| Overhead | 15% idle CPU, 36% idle memory |
| Spot risk | Same as current |
| Pros | Right-sized, cheaper |
| Cons | Tighter scheduling, need redistribution |

### Option C: e2-standard-8 On-Demand + 1-Year CUD — 4 nodes

Same sizing but on-demand with CUD for zero preemption.

| Metric | Value |
|---|---|
| Nodes | 4 x e2-standard-8 on-demand + CUD |
| Cost | **$500 USD / ~$775 AUD per month** (CUD price) |
| Savings | **NEGATIVE — costs MORE than current spot** |
| Spot risk | None — zero preemption |
| Pros | Rock-solid stability for databases |
| Cons | 40% more expensive than current spot |

### Option D: Mixed Pool — Stateful On-Demand + Stateless Spot (RECOMMENDED)

Split into 2 node pools:

**Pool 1: "stateful" — On-Demand (or CUD)**
- Machine: e2-standard-8
- Nodes: 3 (one per zone — required for zonal PVCs)
- Taint: `workload=stateful:PreferNoSchedule`
- Runs: PostgreSQL (6), Redis (5), MongoDB (1), NATS (3), Keycloak Redis (2) = 17 StatefulSet pods
- Resource requests: ~7.4 vCPU, ~14.6 Gi
- Cost with 1-year CUD: 3 x $125 = **$375/mo USD**

**Pool 2: "stateless" — Spot**
- Machine: e2-standard-8
- Nodes: autoscale 1-3
- Runs: ArgoCD, Istio, OpenPanel, identity, marketplace, fanzone, translation, etc.
- Resource requests: ~19.9 vCPU, ~35.5 Gi
- Cost with spot: 2-3 x $59 = **$118-177/mo USD**

| Metric | Value |
|---|---|
| Total nodes | 5-6 (3 stateful + 2-3 stateless) |
| Total cost | **$493-552 USD / ~$764-855 AUD per month** |
| Savings vs current | **SIMILAR or slightly more** |
| Spot risk | **Zero for databases** — spot only for stateless workloads |
| Pros | Best reliability, databases never preempted |
| Cons | More complex, slightly more expensive |

### Option E: Downsize to e2-standard-8 Spot + Reduce Resource Requests (BEST VALUE)

First reduce over-requested resources, THEN downsize nodes.

**Step 1: Reduce overprovisioned requests:**
- translation namespace: 650m CPU req for 9m actual → reduce to 200m (save 450m)
- openpanel: 3450m req for 933m actual → reduce to 1500m (save 1950m)
- growthbook: 1300m req for 263m actual → reduce to 500m (save 800m)
- marketplace (25 pods with 0 replicas still have resource requests counted) → delete deployments (save ~4550m)
- homechef: 1700m req for minimal usage → reduce to 500m (save 1200m)

After optimization: requests drop from 27.3 → ~19 vCPU

**Step 2: Use 3 x e2-standard-8 spot**
- 3 x 7.9 = 23.7 vCPU allocatable → fits 19 vCPU with 25% headroom
- 3 x 29.3 = 87.9 Gi → fits comfortably

| Metric | Value |
|---|---|
| Nodes | 3 x e2-standard-8 spot |
| Cost | **$177 USD / ~$274 AUD per month** |
| Savings vs current | **$180 USD / ~$279 AUD per month (50%)** |
| Spot risk | Same as current (acceptable — already running spot) |
| Pros | Cheapest option, minimal disruption |
| Cons | Needs request tuning first |

---

## 5. Spot Instance Impact on StatefulSets — Reality Check

**You're ALREADY running spot instances and it's working fine.** The concerns about ILBs are unfounded because:

1. **ILB IPs are permanent** — `10.10.0.34` through `10.10.0.42` are GCP forwarding rules. They NEVER change, even when pods/nodes move.

2. **Cloud Run VPC connectors** route to ILB IPs, not to pod IPs. So when a PostgreSQL pod reschedules after spot preemption, Cloud Run services automatically reconnect through the same stable ILB IP.

3. **K8s Services** (ClusterIP and LoadBalancer) provide stable virtual IPs regardless of pod placement.

**What actually happens during spot preemption:**
```
1. GCP marks node for preemption (30s notice)
2. kubelet drains pods gracefully
3. PostgreSQL pod: SIGTERM → checkpoint → shutdown (5-15s)
4. Pod rescheduled to node in same zone (PVC is zonal)
5. PostgreSQL starts, recovers WAL → ready (10-30s)
6. ILB health check passes → traffic flows again
7. Total downtime: ~30-90 seconds
```

**This is the same behavior whether nodes are e2-standard-16 or e2-standard-8.** Smaller nodes don't change the preemption behavior.

---

## 6. Recommendation

### Best Option: E (Reduce requests + downsize to 3x e2-standard-8 spot)

**Phase 1: Delete zero-replica marketplace deployments in GKE** (free up 4.5 vCPU requests)
- 16 marketplace deployments scaled to 0 still have resource requests in scheduler's view
- Action: `kubectl delete deployment <name> -n marketplace` for all 16

**Phase 2: Reduce overprovisioned resource requests**
- Target namespaces: translation, openpanel, growthbook, homechef
- This is done via Helm values in ArgoCD

**Phase 3: Change node pool in Terraform**
```hcl
node_pools = [
  {
    name           = "optimized"
    machine_type   = "e2-standard-8"   # Changed from e2-standard-16
    disk_size_gb   = 80                # Reduced from 100
    disk_type      = "pd-standard"
    spot           = true
    total_min_count = 3                # 3 zones with PVCs
    total_max_count = 5
    location_policy = "BALANCED"       # Ensure zone coverage
    # ... rest same
  }
]
```

**Expected result:**
- Monthly cost: **~$274 AUD** (vs ~$553 AUD current)
- Savings: **~$279 AUD/month ($3,348/year)**
- Same spot behavior as today
- ILBs remain stable
- StatefulSets continue working identically

---

## 7. Summary Comparison Table

| Option | Nodes | Cost (AUD/mo) | Savings/mo | DB Downtime Risk | Effort |
|---|---|---|---|---|---|
| A: Current (no change) | 3x e2-std-16 spot | $553 | $0 | 30-90s preemptions | None |
| B: e2-std-8 spot (4 nodes) | 4x e2-std-8 spot | $366 | $187 | Same as current | Low |
| C: e2-std-8 on-demand + CUD | 4x e2-std-8 CUD | $775 | -$222 (more expensive) | Zero | Low |
| D: Mixed pools | 3 on-demand + 2-3 spot | $764-855 | -$200 to -$300 | Zero for DBs | High |
| **E: Reduce requests + e2-std-8 spot** | **3x e2-std-8 spot** | **$274** | **$279** | **Same as current** | **Medium** |

**Option E is the clear winner** — halves your GKE compute bill while keeping the same spot behavior you already have.
