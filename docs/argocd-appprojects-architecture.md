# ArgoCD AppProjects Architecture

## What We Had Before

Every single app — whether it was a database, a fanzone game service, or the main website — was dumped into one big bucket called `default`. ArgoCD treated all 120+ applications the same way. No separation, no boundaries, no way to tell at a glance "these are my fanzone services" vs "these are infrastructure components."

Think of it like having one massive folder on your desktop with every file you own. Finding anything is painful, and accidentally deleting the wrong thing is easy.

## What We Did

We created **9 separate projects** (like labeled folders) and moved every application into the right one.

```
Before:  default (120 apps — everything mixed together)

After:   infrastructure (27)  — the plumbing
         data (18)            — databases and caches
         identity (3)         — login systems
         platform (5)         — shared services
         marketplace (22)     — mark8ly product
         fanzone (24)         — fanzone product
         homechef (10)        — homechef product
         hms (13)             — hospital management product
         bookkeeping (8)      — bookkeeping product
         default (9)          — bootstrap apps only
```

## The 9 Projects Explained

### infrastructure
**What's in it:** Istio (service mesh), cert-manager (TLS certificates), KEDA (autoscaling), External Secrets Operator, Cloudflare tunnels, NATS (messaging), GrowthBook (feature flags), Typesense (search).

**Why it's separate:** These are the foundations that everything else runs on. If someone pushes a bad config to a fanzone service, it can't accidentally break Istio or certificates. Only infrastructure changes can touch infrastructure namespaces.

### identity
**What's in it:** Google Identity Platform wiring — the auth-BFF deployments and the admin-claim enforcement job.

**Why it's separate:** Authentication is critical. Isolating it means product teams can't accidentally interfere with the login system. Identity changes are reviewed independently.

### data
**What's in it:** 6 PostgreSQL databases (one per product), 5 Redis caches, 1 MongoDB (fanzone chat), and all database backup jobs.

**Why it's separate:** Databases are stateful and dangerous to mess with. By isolating them, only data-specific changes can affect databases. A marketplace code deploy can never accidentally touch the fanzone database config.

### platform
**What's in it:** Shared services used across all products — auth-bff (authentication proxy), tesserix-home (main website), tenant service, audit service, notification service, settings, subscriptions, tickets, document service, etc.

**Why it's separate:** These are the backbone services that multiple products depend on. Changes here need extra care because they affect everyone.

### marketplace
**What's in it:** All mark8ly marketplace services — products, orders, payments, inventory, shipping, categories, coupons, reviews, vendors, customers, staff, content, approvals, gift cards, marketing, tax, connector, plus the admin panel, storefront, and onboarding.

**Why it's separate:** The marketplace team can see only their services in the ArgoCD dashboard. Their deploys can only target the `marketplace` namespace. They can't accidentally deploy to fanzone or homechef.

### fanzone
**What's in it:** All fanzone battle ground services — API, auth, chat, prediction, sportsbook, cricket quiz, game, quest, media, moderation, notification, web, websocket, and sports data.

**Why it's separate:** Same reason as marketplace — fanzone is its own product with its own team, its own namespace, its own lifecycle.

### homechef
**What's in it:** HomeChef food delivery services — API, admin portal, vendor portal, delivery portal, web frontend, auth BFF, and database seed jobs.

**Why it's separate:** HomeChef runs on its own domain (fe3dr.com), its own Cloudflare tunnel, its own database. Complete isolation makes sense.

### hms
**What's in it:** Hospital Management System — appointment, auth, billing, CRM, gateway, patient portal, patient service, staff portal, tenant service, vitals, and international patient service.

**Why it's separate:** Healthcare software has compliance requirements. Isolating HMS means its deployment lifecycle is independent from entertainment (fanzone) or e-commerce (marketplace).

### bookkeeping
**What's in it:** Bookkeeping app services — auth, core accounting, customer, invoice, report, tax, and web frontend.

**Why it's separate:** Financial software, like healthcare, benefits from isolation. Bookkeeping changes don't risk affecting other products.

## How It Works Technically

### Before (flat structure)
```
ArgoCD saw:
  prod-bootstrap
    └── prod-apps
         └── global-app-of-apps    (project: default)
         └── fanzone-app-of-apps   (project: default)
         └── ...all apps            (project: default)
    └── prod-infrastructure
         └── ...all infra apps      (project: default)
```

Every app could deploy to any namespace. No restrictions.

### After (project-isolated structure)
```
ArgoCD sees:
  prod-bootstrap
    └── prod-apps
         └── global-app-of-apps    (project: platform)
         └── fanzone-app-of-apps   (project: fanzone)
         └── marketplace-app-of-apps (project: marketplace)
         └── ...each product's apps  (project: <product>)
    └── prod-infrastructure
         └── istio, certs, etc.     (project: infrastructure)
         └── databases, redis       (project: data)
         └── auth-bff               (project: identity)
```

Each project has rules:
- **Which Git repos** it can pull from
- **Which namespaces** it can deploy to
- **Which cluster resources** it can create

Example: The `fanzone` project can only deploy to the `fanzone` namespace from the `tesserix/tesserix-k8s` repo. It physically cannot deploy to `marketplace` or `homechef`.

## What This Gives Us

### 1. Easy Monitoring
Open ArgoCD dashboard, filter by project `fanzone` — you see only fanzone services. No noise from 100 other apps. You can instantly tell if fanzone is healthy or not.

### 2. Blast Radius Control
If a bad Helm value is pushed for a marketplace service, the worst that can happen is marketplace breaks. It cannot cascade to fanzone, homechef, or infrastructure. The project boundaries act as firewalls.

### 3. Independent Bootstrapping
Want to spin up a new environment for just homechef? Apply the `homechef` project and its app-of-apps — done. You don't need to bring up the entire platform. Each product is self-contained.

### 4. Team Ownership
In the future, you can assign RBAC roles per project:
- Fanzone team: read/write on `fanzone` project only
- Platform team: read/write on `platform` and `infrastructure`
- Data team: read/write on `data` project only

This means teams can self-serve deploys without risking each other's services.

### 5. Cleaner Git History
When reviewing PRs, you can immediately tell the scope of change by looking at which project directory was modified. A PR touching `argocd/prod/apps/fanzone/` only affects fanzone — no surprises.

## Architecture Diagram

```
                        ┌─────────────────────┐
                        │   prod-bootstrap     │
                        │   (project: default) │
                        └──────────┬──────────┘
                    ┌──────────────┴──────────────┐
                    ▼                              ▼
        ┌───────────────────┐          ┌────────────────────┐
        │   prod-apps       │          │ prod-infrastructure │
        │ (project: default)│          │ (project: default)  │
        └────────┬──────────┘          └─────────┬──────────┘
                 │                               │
    ┌────────────┼─────────────┐     ┌───────────┼───────────┐
    ▼            ▼             ▼     ▼           ▼           ▼
┌────────┐ ┌──────────┐ ┌────────┐ ┌──────┐ ┌──────┐ ┌──────────┐
│platform│ │marketplace│ │fanzone │ │infra │ │ data │ │ identity │
│ 5 apps │ │ 22 apps  │ │24 apps │ │27apps│ │18apps│ │  3 apps  │
└────────┘ └──────────┘ └────────┘ └──────┘ └──────┘ └──────────┘
    │            │             │
┌────────┐ ┌──────────┐ ┌────────┐
│homechef│ │   hms    │ │  bka   │
│10 apps │ │ 13 apps  │ │ 8 apps │
└────────┘ └──────────┘ └────────┘
```

## Namespace Mapping

Each project is locked to specific namespaces:

| Project | Allowed Namespaces |
|---------|-------------------|
| infrastructure | istio-system, istio-ingress, istio-egress, cert-manager, external-dns, external-secrets, keda, cloudflared, nats, monitoring, logging, growthbook, typesense, translation, marketplace |
| identity | identity-customer, identity-internal |
| data | postgresql-global, postgresql-marketplace, postgresql-bookkeeping, postgresql-hms, postgresql-fanzone, postgresql-homechef, redis-global, redis-marketplace, redis-hms, redis-fanzone, redis-homechef, redis-tesserix, mongodb-fanzone, db-backup-and-restore |
| platform | marketplace, global, translation, tesserix, yes-hospital |
| marketplace | marketplace |
| fanzone | fanzone |
| homechef | homechef |
| hms | hms |
| bookkeeping | bookkeeping |

## What Didn't Change

- **No workloads were restarted.** This was purely an ArgoCD metadata change.
- **No services went down.** We only changed which "folder" each app belongs to.
- **The app-of-apps pattern is the same.** We didn't restructure how apps are deployed.
- **Git repo structure is the same.** Files are in the same directories.
- **Helm charts are untouched.** No application configuration was modified.

## Files That Were Changed

| Location | What Changed |
|----------|-------------|
| `argocd/prod/projects/` (new) | 9 AppProject YAML files + kustomization |
| `argocd/prod/kustomization.yaml` | Added `projects/` as a resource |
| `argocd/prod/apps/**/*.yaml` | Changed `project: default` to correct project |
| `argocd/prod/infrastructure/**/*.yaml` | Changed `project: default` to correct project |
| `argocd/prod/apps/hms/kustomization.yaml` | Fixed broken YAML (missing list markers) |
| `argocd/prod/apps/bookkeeping/kustomization.yaml` | Fixed broken YAML (missing list markers) |
| `argocd/prod/apps/hms/*.yaml` | Fixed values-prod.yaml indentation |
| `argocd/prod/apps/bookkeeping/*.yaml` | Fixed values-prod.yaml indentation |

## How to Add a New Product

1. Create a new AppProject file in `argocd/prod/projects/`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AppProject
   metadata:
     name: my-new-product
     namespace: argocd
   spec:
     sourceRepos:
       - https://github.com/tesserix/tesserix-k8s.git
     destinations:
       - namespace: my-new-product
         server: https://kubernetes.default.svc
   ```

2. Add it to `argocd/prod/projects/kustomization.yaml`

3. Create the app-of-apps in `argocd/prod/apps/`

4. Each app in the new product uses `project: my-new-product`

The new product is completely isolated from day one.
