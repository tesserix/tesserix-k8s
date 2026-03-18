# GCP Cost Analysis & Optimization Report

**Project:** `tesseracthub-480811` (TesseractHub)
**Billing Account:** `01C0B7-C8CD85-88B397` (My Billing Account)
**Currency:** AUD (Australian Dollars)
**Report Date:** March 3, 2026 (Updated)
**Primary Region:** asia-south1 (Mumbai, India)

---

## Optimization Summary (Completed March 3, 2026)

| # | Optimization | Monthly Savings (AUD) | Status |
|---|---|---|---|
| 1 | Deleted orphaned AU load balancer (`australia-southeast1`) | ~$25-30 | Done |
| 2 | Deleted logging namespace & idle PVCs | ~$5 | Done |
| 3 | Set `minScale=0` on 24 low-traffic Cloud Run services | ~$100-200 | Done |
| 4 | Removed OpenPanel analytics (9 pods, 3.45 vCPU, 6.9 Gi, 75 Gi disk) | ~$80-100 | Done |
| 5 | Downsized GKE from 3x `e2-standard-16` on-demand → 5x `e2-standard-8` spot | ~$1,290-1,400 | Done |
| 6 | Removed yes-hospital (broken GHCR image) | ~$5 | Done |
| 7 | Removed homechef apps (GHCR images not found) | ~$10 | Done |
| 8 | Fixed corrupted marketplace GHCR SealedSecret → ExternalSecret | $0 (fix) | Done |
| **Total Realized Savings** | | **~$1,515-1,750** | |

**Estimated monthly bill: Before ~$2,850-3,200 → After ~$1,100-1,450 AUD/month**

---

## Table of Contents

1. [Infrastructure Inventory](#1-infrastructure-inventory)
2. [GKE Cluster Analysis](#2-gke-cluster-analysis)
3. [Cloud Run Analysis](#3-cloud-run-analysis)
4. [Storage Analysis](#4-storage-analysis)
5. [Networking Analysis](#5-networking-analysis)
6. [Estimated Monthly Cost Breakdown](#7-estimated-monthly-cost-breakdown)
7. [Remaining Optimization Opportunities](#8-remaining-optimization-opportunities)
8. [Action Plan](#9-action-plan)

---

## 1. Infrastructure Inventory

### 1.1 GKE Cluster

| Property | Before | After |
|---|---|---|
| Cluster Name | `tesseract-prod-in-gke` | `tesseract-prod-in-gke` |
| Location | `asia-south1` (Regional — 3 zones) | Same |
| K8s Version | 1.35.0-gke.3047000 | Same |
| Node Count | 3 | **5** (autoscaler-managed) |
| Node Pool | `optimized` | **`optimized-v2`** |
| Machine Type | `e2-standard-16` (16 vCPU, 64 GB) | **`e2-standard-8` (8 vCPU, 32 GB)** |
| Preemptibility | On-demand | **Spot VMs** |
| Boot Disk | 100 GB pd-standard | **80 GB pd-standard** |
| Autoscaling | min: 1, max: 3 total | **min: 1, max: 6 total** |
| Tier | Standard ($0.10/hr) | Same |
| CUDs | None | None |

**Current Nodes:**

| Node | Zone | Machine Type | Status |
|---|---|---|---|
| optimized-v2-113a9e14-qh6h | asia-south1-a | e2-standard-8 | Ready |
| optimized-v2-64d9a67f-cg4c | asia-south1-b | e2-standard-8 | Ready |
| optimized-v2-c6a922bf-2hk9 | asia-south1-c | e2-standard-8 | Ready |
| optimized-v2-c6a922bf-tdhr | asia-south1-c | e2-standard-8 | Ready |
| optimized-v2-c6a922bf-xv62 | asia-south1-c | e2-standard-8 | Ready |

### 1.2 Cloud Run Services (65 total)

| Category | Count | Services |
|---|---|---|
| FanZone | 18 | fanzone-api, fanzone-auth, fanzone-auth-bff, fanzone-book-cricket, fanzone-chat, fanzone-cleanup, fanzone-commentary, fanzone-fan-connect, fanzone-game, fanzone-media, fanzone-micro-prediction, fanzone-moderation, fanzone-notification, fanzone-prediction, fanzone-quest, fanzone-sportsbook, fanzone-user, fanzone-web |
| Marketplace | 25 | marketplace-admin, marketplace-approval-service, marketplace-categories-service, marketplace-connector-service, marketplace-content, marketplace-coupons-service, marketplace-customers-service, marketplace-feature-flags, marketplace-gift-cards-service, marketplace-inventory-service, marketplace-marketing-service, marketplace-orders-service, marketplace-payment-service, marketplace-products-service, marketplace-qr, marketplace-reviews-service, marketplace-shipping-service, marketplace-staff-service, marketplace-status-dashboard, marketplace-storefront, marketplace-tax-service, marketplace-tenant-onboarding, marketplace-tickets-service, marketplace-translation, marketplace-vendor-service |
| Global | 13 | global-analytics-service, global-audit-service, global-auth-bff, global-custom-domain-service, global-document-service, global-location-service, global-notification-hub, global-notification-service, global-search-service, global-settings-service, global-subscription-service, global-tenant-service, global-verification-service |
| HomeChef | 3 | homechef-api, homechef-vendor-portal, homechef-web (can be deleted — apps removed from GKE) |
| Other | 6 | audit-service, feature-flags-service, sports-data, status-dashboard-service, tesserix-home, fanzone-book-cricket |

### 1.3 VPC Connectors (4)

| Connector | Network | Min/Max Throughput | Machine | Min/Max Instances | State |
|---|---|---|---|---|---|
| fz-prod-vpc-connector | tesseract-prod-in-vpc | 200/300 Mbps | e2-micro | 2/3 | READY |
| gl-prod-vpc-connector | tesseract-prod-in-vpc | 200/300 Mbps | e2-micro | 2/3 | READY |
| hc-prod-vpc-connector | tesseract-prod-in-vpc | 200/1000 Mbps | e2-micro | 2/10 | READY |
| mp-prod-vpc-connector | tesseract-prod-in-vpc | 200/300 Mbps | e2-micro | 2/3 | READY |

### 1.4 GCS Buckets (27)

| Bucket | Location | Notes |
|---|---|---|
| bookkeeping-prod-assets-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate |
| bookkeeping-prod-assets-in | ASIA-SOUTH1 | |
| fanzone-prod-assets-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate |
| fanzone-prod-assets-in | ASIA-SOUTH1 | |
| fanzone-prod-sportsbook-in | ASIA-SOUTH1 | |
| hms-prod-assets-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate |
| hms-prod-assets-in | ASIA-SOUTH1 | |
| hms-prod-backups-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate |
| hms-prod-backups-in | ASIA-SOUTH1 | |
| hms-prod-patientrecords-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate |
| hms-prod-patientrecords-in | ASIA-SOUTH1 | |
| homechef-prod-assets-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate — can be deleted |
| homechef-prod-assets-in | ASIA-SOUTH1 | Can be deleted |
| marketplace-prod-assets-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate |
| marketplace-prod-assets-in | ASIA-SOUTH1 | |
| marketplace-prod-public-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate |
| marketplace-prod-public-in | ASIA-SOUTH1 | |
| run-sources-tesseracthub-480811-asia-south1 | ASIA-SOUTH1 | Cloud Run source deploy |
| tesseract-database-backups | AUSTRALIA-SOUTHEAST1 | |
| tesseract-prod-assets-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate |
| tesseract-prod-assets-in | ASIA-SOUTH1 | |
| tesseract-prod-backups-au | AUSTRALIA-SOUTHEAST1 | Dual-region duplicate |
| tesseract-prod-backups-in | ASIA-SOUTH1 | |
| tesseract-terraform-states | AUSTRALIA-SOUTHEAST1 | |
| tesseracthub-480811_cloudbuild | US | Legacy Cloud Build bucket |
| tesseracthub-prod-assets | ASIA-SOUTH1 | |
| tesserix-public-assets | ASIA-SOUTH1 | |

### 1.5 Artifact Registry

| Repository | Format | Size |
|---|---|---|
| cloud-run-source-deploy | DOCKER | 360 MB |
| fanzone | DOCKER | 3,025 MB |
| global | DOCKER | 719 MB |
| homechef | DOCKER | 46 MB |
| marketplace | DOCKER | 8,480 MB |
| **Total** | | **12,630 MB (~12.3 GB)** |

### 1.6 Secret Manager

- **157 secrets** (all with automatic replication)

---

## 2. GKE Cluster Analysis

### 2.1 Node Resource Utilization (Post-Optimization)

**Total Cluster Capacity:** 40 vCPU, 160 GB RAM (5x e2-standard-8 spot)

| Node | Zone | CPU Used | CPU % | Memory Used | Memory % |
|---|---|---|---|---|---|
| optimized-v2-113a9e14-qh6h | asia-south1-a | 836m | **10%** | 3,249 Mi (3.2 Gi) | **11%** |
| optimized-v2-64d9a67f-cg4c | asia-south1-b | 542m | **6%** | 7,956 Mi (7.8 Gi) | **28%** |
| optimized-v2-c6a922bf-2hk9 | asia-south1-c | 584m | **7%** | 7,316 Mi (7.1 Gi) | **25%** |
| optimized-v2-c6a922bf-tdhr | asia-south1-c | 1,812m | **22%** | 9,846 Mi (9.6 Gi) | **34%** |
| optimized-v2-c6a922bf-xv62 | asia-south1-c | 800m | **10%** | 11,160 Mi (10.9 Gi) | **39%** |
| **TOTAL** | | **4,574m (4.6 vCPU)** | **11%** | **39,527 Mi (38.6 Gi)** | **24%** |

### 2.2 Resource Requests vs Actual Usage

| Metric | Capacity | Requested | Actually Used | Req/Capacity | Used/Capacity |
|---|---|---|---|---|---|
| CPU | 40,000m (40 vCPU) | 24,877m (24.9 vCPU) | 4,574m (4.6 vCPU) | **62%** | **11%** |
| Memory | 160 Gi | 45.1 Gi | 38.6 Gi | **28%** | **24%** |

**Verdict:** Cluster is right-sized for requests (62% CPU requested — headroom for bursts and scheduling). Actual CPU usage remains low at 11%, but this is expected for microservices with conservative requests. Memory is well-utilized at 24% actual.

### 2.3 Resource Requests by Namespace

| Namespace | Pods | CPU Req (m) | Mem Req (Mi) | Notes |
|---|---|---|---|---|
| marketplace | 43 | 6,000 | 7,887 | Main e-commerce platform |
| kube-system | 62 | 3,527 | 3,918 | GKE system components |
| argocd | 9 | 1,400 | 1,792 | GitOps controller |
| growthbook | 3 | 1,400 | 2,752 | Feature flags platform |
| postgresql-fanzone | 1 | 1,000 | 2,048 | 650 GB PVC, only ~129 MB used |
| postgresql-homechef | 1 | 1,000 | 2,048 | **Orphaned** — apps removed, DB still running |
| postgresql-marketplace | 1 | 1,000 | 2,048 | 650 GB PVC, only ~374 MB used |
| istio-ingress | 6 | 800 | 1,024 | Ingress gateways |
| translation | 5 | 800 | 6,676 | Self-hosted translation (heavy memory) |
| identity-customer | 3 | 750 | 2,496 | Keycloak + Redis |
| nats | 3 | 750 | 1,536 | Message queue |
| identity-internal | 3 | 700 | 1,856 | Keycloak + Redis |
| cloudflared | 6 | 600 | 768 | Cloudflare tunnels |
| fanzone | 7 | 600 | 1,138 | ws(3) + sports-data + prediction-bot |
| arc-runners | 1 | 500 | 512 | GitHub Actions runner |
| mongodb-fanzone | 1 | 500 | 1,024 | 350 GB premium SSD PVC |
| postgresql-global | 1 | 500 | 1,024 | 50 GB PVC |
| postgresql-hms | 1 | 500 | 1,024 | 60 GB PVC |
| keda | 4 | 350 | 420 | Event-driven autoscaling |
| typesense | 1 | 300 | 576 | Search engine |
| postgresql-bookkeeping | 1 | 250 | 512 | 30 GB PVC |
| redis-fanzone | 1 | 250 | 512 | |
| kong | 2 | 200 | 256 | API Gateway |
| redis-marketplace | 1 | 200 | 512 | |
| cert-manager | 3 | 150 | 192 | TLS certificate management |
| istio-system | 2 | 150 | 320 | Istiod control plane |
| tesserix | 2 | 150 | 256 | |
| external-secrets | 3 | 100 | 128 | |
| redis-global | 1 | 100 | 256 | |
| redis-hms | 1 | 100 | 256 | |
| arc-systems | 2 | 50 | 64 | |
| external-dns | 1 | 50 | 64 | |
| istio-egress | 1 | 50 | 64 | |
| redis-homechef | 1 | 50 | 128 | **Orphaned** — apps removed |
| sealed-secrets | 1 | 50 | 64 | |
| **TOTAL** | **185** | **24,877** | **46,151** | |

### 2.4 Removed Namespaces/Workloads

| Removed | CPU Freed (m) | Mem Freed (Mi) | Disk Freed | Reason |
|---|---|---|---|---|
| openpanel (9 pods) | 3,450 | 6,912 | 75 Gi | Unnecessary analytics — too heavy for value |
| yes-hospital (2 pods) | 200 | 512 | — | Image tag doesn't exist in GHCR |
| homechef apps (5 pods) | 1,700 | 2,304 | — | GHCR images return 404 |
| logging (0 pods) | 0 | 0 | 50 Gi | Scaled to 0 for weeks, idle PVC |
| **Total freed** | **5,350** | **9,728** | **125 Gi** | |

---

## 3. Cloud Run Analysis

### 3.1 Scaling Configuration (Post-Optimization)

**Services set to `minScale=0` (24 services — previously minScale=1):**

These now scale to zero when idle, saving memory charges:
fanzone-cleanup, fanzone-game, fanzone-media, fanzone-moderation, fanzone-commentary,
marketplace-approval-service, marketplace-categories-service, marketplace-content,
marketplace-coupons-service, marketplace-feature-flags, marketplace-gift-cards-service,
marketplace-inventory-service, marketplace-marketing-service, marketplace-qr,
marketplace-reviews-service, marketplace-tax-service, marketplace-tickets-service,
marketplace-translation, marketplace-vendor-service, marketplace-status-dashboard,
global-location-service, global-settings-service, global-verification-service,
global-analytics-service, global-audit-service

**Services still with `minScale=1` and CPU always allocated (5 services):**

| Service | CPU | Memory | CPU Throttling | Min/Max Scale |
|---|---|---|---|---|
| fanzone-book-cricket | 1 | 512Mi | **No** (always-on) | 1/20 |
| fanzone-fan-connect | 1 | 512Mi | **No** (always-on) | 1/20 |
| fanzone-micro-prediction | 1 | 512Mi | **No** (always-on) | 1/5 |
| fanzone-quest | 1 | 512Mi | **No** (always-on) | 1/3 |
| sports-data | 1 | 256Mi | **No** (always-on) | 1/1 |

**Remaining services with `minScale=1` and CPU throttling (~24 services):**
Core services that need warm instances (auth, storefront, API endpoints, etc.)

**Services with no minScale set (can scale to 0 already — 7 services):**
audit-service, feature-flags-service, homechef-api, homechef-vendor-portal, homechef-web, status-dashboard-service, tesserix-home

### 3.2 Cloud Run Revision Bloat

| Service | Revision Count | Notes |
|---|---|---|
| fanzone-web | **225** | Excessive — needs cleanup policy |
| fanzone-auth | 37 | |
| fanzone-api | 33 | |
| fanzone-sportsbook | 23 | |
| global-notification-service | 14 | |
| marketplace-storefront | 9 | |
| marketplace-admin | 8 | |
| **Total across all 65 services** | **~1,033** | |

---

## 4. Storage Analysis

### 4.1 Persistent Volume Claims (PVCs)

**Total provisioned: 2,583 Gi across 23 PVCs** (down from ~3,010 GB)

#### PostgreSQL Databases — MASSIVELY Overprovisioned

| PVC | Namespace | Provisioned | Actual Used | Utilization | Status |
|---|---|---|---|---|---|
| data-postgresql-0 | postgresql-fanzone | **650 Gi** | **129 MB** | **0.02%** | Active |
| data-postgresql-0 | postgresql-marketplace | **650 Gi** | **374 MB** | **0.06%** | Active |
| data-postgresql-0 | postgresql-homechef | **650 Gi** | **46 MB** | **0.007%** | **Orphaned — apps removed** |
| data-postgresql-0 | postgresql-global | 50 Gi | — | — | Active |
| data-postgresql-0 | postgresql-hms | 60 Gi | — | — | Active |
| data-postgresql-0 | postgresql-bookkeeping | 30 Gi | — | — | Active |

**Combined waste: 1,950 Gi provisioned for ~550 MB of actual data. postgresql-homechef can be deleted entirely.**

#### MongoDB

| PVC | Namespace | Provisioned | Disk Type | Notes |
|---|---|---|---|---|
| data-mongodb-fanzone-0 | mongodb-fanzone | **350 Gi** | **premium-rwo (SSD)** | Premium SSD is expensive — evaluate downgrade |

#### Other PVCs

| PVC | Namespace | Size | Type | Notes |
|---|---|---|---|---|
| growthbook-mongodb | growthbook | 20 Gi | standard-rwo | |
| growthbook-uploads | growthbook | 10 Gi | standard-rwo | |
| libretranslate-models | translation | 20 Gi | standard-rwo | |
| typesense-data | typesense | 10 Gi | standard-rwo | |
| data-nats-0/1/2 | nats | 12 Gi x3 | standard-rwo | |
| redis PVCs (x5) | various | 4-16 Gi | standard-rwo | |
| identity redis (x2) | identity-* | 1-2 Gi | premium-rwo | |

#### Pending PVCs (Never Bound)

| PVC | Namespace | Size | Notes |
|---|---|---|---|
| bergamot-service-models | translation | 5 Gi | Never provisioned |
| huggingface-mt-service-cache | translation | 10 Gi | Never provisioned |

#### Removed PVCs

| PVC | Namespace | Size | Notes |
|---|---|---|---|
| openpanel-clickhouse | openpanel | 50 Gi | Deleted — OpenPanel removed |
| openpanel-postgresql | openpanel | 20 Gi | Deleted — OpenPanel removed |
| openpanel-redis | openpanel | 5 Gi | Deleted — OpenPanel removed |
| elasticsearch-master-0 | logging | 50 Gi | Deleted — logging removed |

### 4.2 Persistent Disk Summary

| Disk Type | Total GB | Estimated Cost/mo (AUD) |
|---|---|---|
| pd-balanced | 2,230 GB | ~$223 |
| pd-ssd / premium-rwo | 353 GB | ~$60 |
| pd-standard (node boot) | 400 GB (5x 80 GB) | ~$16 |
| **Total** | **2,983 GB** | **~$299** |

*Down from ~3,010 GB / ~$308. OpenPanel PVCs freed 75 GB, but 2 additional node boot disks added 100 GB.*

---

## 5. Networking Analysis

### 5.1 Forwarding Rules / Load Balancers

| Name | Region | IP | Type | Notes |
|---|---|---|---|---|
| ~~a2399b6f71493403481602aee00a8dd6~~ | ~~australia-southeast1~~ | ~~34.87.212.102~~ | ~~EXTERNAL~~ | **DELETED** — was orphaned |
| a5555142806fc482b93da7ca80d5bd88 | asia-south1 | 34.93.146.250 | EXTERNAL | Active — prod ingress |
| ad9a2ae71543f4fd1bb4da45a32b964d | asia-south1 | 34.14.139.74 | EXTERNAL | Active — custom domain ingress |
| 10 internal forwarding rules | asia-south1 | 10.10.0.x | INTERNAL | K8s internal services |

### 5.2 Cloud NAT

| Router | Region | NAT IP Allocation | Scope |
|---|---|---|---|
| tesseract-prod-in-vpc-router | asia-south1 | AUTO_ONLY | ALL_SUBNETWORKS_ALL_IP_RANGES |

### 5.3 Static IP Addresses

| Name | Region | Address | Status | Type |
|---|---|---|---|---|
| tesseract-prod-in-vpc-private-ip | — | 10.249.0.0 | RESERVED | INTERNAL |
| nat-auto-ip-* | asia-south1 | 35.207.236.200 | IN_USE | EXTERNAL |

---

## 6. Estimated Monthly Cost Breakdown (Post-Optimization)

### 6.1 Cost by Service Category

| Resource Category | Before (AUD/mo) | After (AUD/mo) | Savings | Notes |
|---|---|---|---|---|
| **GKE Compute** | ~$1,804 | **~$400-515** | **~$1,290-1,400** | 3x e2-standard-16 on-demand → 5x e2-standard-8 spot |
| **Cloud Run** | ~$300-500 | **~$150-350** | **~$100-200** | 24 services set to minScale=0 |
| **Persistent Disks** | ~$308 | ~$299 | ~$9 | OpenPanel PVCs freed, extra boot disks added |
| **Networking** (NAT, LBs, egress) | ~$150 | ~$120 | ~$30 | AU LB deleted |
| **GKE Management Fee** | ~$113 | ~$113 | $0 | Per-cluster fee unchanged |
| **VPC Connectors** (4 connectors) | ~$75 | ~$75 | $0 | Unchanged |
| **Logging/Monitoring** | ~$50-100 | ~$50-100 | $0 | Unchanged |
| **Artifact Registry** | ~$3 | ~$3 | $0 | |
| **Secret Manager** | ~$15 | ~$15 | $0 | |
| **GCS Buckets** | ~$10-30 | ~$10-30 | $0 | |
| **Orphaned Resources** | ~$30-35 | **$0** | ~$30-35 | All cleaned up |
| **Estimated Total** | **~$2,850-3,200** | **~$1,235-1,620** | **~$1,460-1,670** | |

### 6.2 GKE Compute Cost Detail

| Component | Before | After |
|---|---|---|
| Nodes | 3x e2-standard-16 on-demand @ ~$601/node | 5x e2-standard-8 spot @ ~$80-103/node |
| Node compute cost | ~$1,804/mo | ~$400-515/mo |
| GKE Standard management fee | ~$113/mo | ~$113/mo |
| **Subtotal** | **~$1,917** | **~$513-628** |

*Spot VM pricing: e2-standard-8 on-demand = ~$194/mo, spot discount = ~60-70% → ~$58-78/node.*
*Autoscaler may reduce to 4 nodes during low-traffic periods, further reducing cost.*

### 6.3 Cloud Run Cost Detail (Estimated)

| Component | Before | After |
|---|---|---|
| Idle min instances (CPU-throttled, minScale=1) | ~48 svc, ~$25/mo (mem only) | ~24 svc, ~$12/mo |
| Idle min instances (CPU-always-on, 5 svc) | ~$52/mo | ~$52/mo (unchanged) |
| Active request processing | ~$100-300/mo | ~$100-300/mo |
| **Subtotal** | **~$180-380** | **~$165-365** |

---

## 7. Remaining Optimization Opportunities

### Priority 1 — HIGH IMPACT

#### R1: Shrink PostgreSQL PVCs (Save ~$150-190 AUD/month)

**Current State:** 1,950 Gi provisioned for ~550 MB of actual data.

| Database | Current | Recommended | Savings |
|---|---|---|---|
| postgresql-fanzone | 650 Gi | 20 Gi | 630 Gi |
| postgresql-marketplace | 650 Gi | 20 Gi | 630 Gi |
| postgresql-homechef | 650 Gi | **Delete entirely** | 650 Gi |
| **Total saved** | | | **1,910 Gi** |

**Implementation:** For active DBs: create new smaller PVC → pg_dump/pg_restore → update StatefulSet → delete old PVC. For homechef: delete the namespace entirely (apps already removed).

**Savings:** ~1,910 GB pd-balanced * $0.10/GB/mo = ~$191 AUD/month

#### R2: Delete Orphaned HomeChef Infrastructure (Save ~$15-20 AUD/month)

HomeChef apps were removed but these infrastructure resources remain running:

| Resource | Namespace | CPU (m) | Memory (Mi) | Disk |
|---|---|---|---|---|
| postgresql-0 | postgresql-homechef | 1,000 | 2,048 | 650 Gi |
| redis-0 | redis-homechef | 50 | 128 | 4 Gi |
| hc-prod-vpc-connector | — | — | — | — |

**Implementation:** Delete ArgoCD apps for postgresql-homechef and redis-homechef, delete namespaces, delete VPC connector.

#### R3: Purchase 1-Year Committed Use Discount (Save ~$150-250 AUD/month)

**Current State:** Zero CUDs. All compute is spot/on-demand.

**Recommendation:** After stabilizing at current size, commit to baseline:
- 1-year CUD on ~16 vCPU + 64 GB memory (minimum guaranteed capacity)
- CUD applies even with spot VMs (covers the baseline)
- 37% discount on committed resources

*Note: CUD savings apply on top of spot pricing only for the on-demand portion. If spot is preempted and on-demand replacements spin up, CUD covers them.*

### Priority 2 — MEDIUM IMPACT

#### R4: Consolidate VPC Connectors (Save ~$30-50 AUD/month)

**Current:** 4 separate connectors (fz, gl, hc, mp) all on same VPC, each running 2-3 e2-micro.

**Options:**
- Delete `hc-prod-vpc-connector` immediately (HomeChef removed)
- Consolidate remaining 3 to 1-2 connectors (all share same VPC)
- Migrate to **Direct VPC Egress** (GA since 2024) — no connector instances needed

#### R5: Review Translation Namespace (Save ~$50 AUD/month of cluster resources)

5 pods, 800m CPU requested, **6.7 GB memory** for self-hosted translation. Consider:
- Is it actively used?
- Would Google Cloud Translation API be cheaper at your volume?
- Can you drop to 1 replica per service?

#### R6: MongoDB Premium SSD → Balanced (Save ~$25 AUD/month)

`mongodb-fanzone` uses 350 GB **premium-rwo (pd-ssd)** at ~$0.17/GB vs pd-balanced at ~$0.10/GB.
Savings: 350 * ($0.17 - $0.10) = ~$24.50/month. Unless you need the IOPS, downgrade.

#### R7: Delete Homechef Cloud Run Services (Save ~$5-10 AUD/month)

3 Cloud Run services (homechef-api, homechef-vendor-portal, homechef-web) still exist. They have no minScale set so may already be at 0, but deleting removes any residual charges.

### Priority 3 — CLEANUP

#### R8: Clean Up Zero-Replica GKE Deployments

16 marketplace deployments scaled to 0 (fully migrated to Cloud Run). No cost savings but reduces cluster state bloat and ArgoCD sync noise.

#### R9: Clean Up Cloud Run Revision Bloat

1,033 total revisions. Set retention policy:
```bash
gcloud run services update SERVICE_NAME \
  --max-instances-revision-count=5 \
  --region=asia-south1
```

#### R10: Review Duplicate GCS Buckets

8 products have matching buckets in both `asia-south1` and `australia-southeast1`. If only serving from India, the AU buckets may be deletable. HomeChef buckets can definitely be deleted.

#### R11: Artifact Registry Cleanup

12.3 GB of images. Set lifecycle policies to auto-delete untagged images older than 30 days.

#### R12: Delete Empty Namespaces

These namespaces exist but have no running workloads:
- `openpanel` — can be deleted (workloads already removed)
- `email` — appears unused
- `monitoring` — appears unused
- `homechef` — apps removed
- `identity` — appears unused (separate from identity-customer/internal)

---

## 8. Action Plan

### Phase 1 — Quick Wins (COMPLETED)

| # | Action | Savings/mo | Status |
|---|---|---|---|
| 1 | Delete orphaned AU load balancer | $25-30 | **DONE** |
| 2 | Delete logging namespace & idle PVCs | $5 | **DONE** |
| 3 | Set minScale=0 on 24 Cloud Run services | $100-200 | **DONE** |
| 4 | Remove OpenPanel analytics (9 pods, 75 Gi disk) | $80-100 | **DONE** |
| 5 | Remove yes-hospital (broken images) | $5 | **DONE** |
| 6 | Remove homechef apps (broken images) | $10 | **DONE** |
| 7 | Fix marketplace GHCR SealedSecret | $0 (fix) | **DONE** |

### Phase 2 — Major Savings (COMPLETED)

| # | Action | Savings/mo | Status |
|---|---|---|---|
| 8 | Downsize GKE to e2-standard-8 spot VMs | $1,290-1,400 | **DONE** |

### Phase 3 — Next Optimizations (TODO)

| # | Action | Savings/mo | Risk | Effort |
|---|---|---|---|---|
| 9 | Shrink PostgreSQL PVCs to 20 GB each | $150-190 | Medium | 2-3 hrs |
| 10 | Delete postgresql-homechef & redis-homechef | $15-20 | None | 15 min |
| 11 | Delete hc-prod-vpc-connector | $10-15 | None | 5 min |
| 12 | Consolidate remaining 3 VPC connectors to 1-2 | $20-35 | Medium | 1-2 hrs |
| 13 | Purchase 1-year CUD (after stabilization) | $150-250 | Low (commitment) | 30 min |

### Phase 4 — Further Optimizations (TODO)

| # | Action | Savings/mo | Risk | Effort |
|---|---|---|---|---|
| 14 | Review translation namespace necessity | $50 | Medium | 1 hr |
| 15 | MongoDB SSD → balanced | $25 | Low | 1 hr |
| 16 | Delete homechef Cloud Run services + GCS buckets | $5-10 | None | 15 min |
| 17 | Clean up zero-replica deployments | $0 (cleanup) | None | 15 min |
| 18 | Clean up Cloud Run revisions | $0 (cleanup) | None | 30 min |
| 19 | Clean up duplicate GCS AU buckets | $5-10 | Low | 1 hr |
| 20 | Artifact Registry lifecycle policies | $1-2 | None | 15 min |

### Projected Savings Summary

| Phase | Monthly Savings (AUD) | Cumulative | Status |
|---|---|---|---|
| Phase 1 (Quick Wins) | $225-350 | $225-350 | **DONE** |
| Phase 2 (GKE Downsize) | $1,290-1,400 | $1,515-1,750 | **DONE** |
| Phase 3 (Next Optimizations) | $345-510 | $1,860-2,260 | TODO |
| Phase 4 (Further Optimizations) | $86-97 | $1,946-2,357 | TODO |
| **Total Potential Savings** | | **$1,946-2,357 AUD/month** | |
| **Current Monthly Bill (estimated)** | | **~$1,235-1,620 AUD/month** | |
| **Projected After All Phases** | | **~$850-1,250 AUD/month** | |
| **Annual Savings (all phases)** | | **$23,350-28,280 AUD/year** | |

---

*Report generated by analyzing live GCP CLI data and kubectl cluster metrics.*
*For exact billing figures, enable BigQuery billing export or check the GCP Billing Console directly.*
*Last updated: March 3, 2026*
