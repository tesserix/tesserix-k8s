# HomeChef Platform Reference (fe3dr.com)

Deployed topology for the HomeChef food-delivery platform. Read this when working
on `charts/apps/homechef-*`, `argocd/prod/apps/homechef/`, or the
`tesserix/Home-Chef-App` application repo.

- **Repo:** `tesserix/Home-Chef-App` (private, pnpm monorepo)
- **Apps:** `apps/web`, `apps/vendor-portal`, `apps/admin-portal`,
  `apps/delivery-portal`, `apps/api`
- **Frontend:** React 19, Vite 6, Tailwind CSS 4, Radix UI, React Router 7,
  TanStack Query, Zustand
- **Backend:** Go 1.25, Gin, GORM, PostgreSQL 16, Redis, NATS JetStream
- **Payments:** Razorpay Route (split payments)
- **CI/CD:** 7 GitHub Actions workflows → GHCR → GKE/ArgoCD
- **Namespace:** `homechef`

## Services (all Knative Serving)

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| `homechef-api` | `ghcr.io/tesserix/home-chef-app/homechef-api` | 8080 | Go/Gin backend API |
| `homechef-web` | `ghcr.io/tesserix/home-chef-app/homechef-web` | 80 | Customer-facing SPA |
| `homechef-vendor-portal` | `ghcr.io/tesserix/home-chef-app/homechef-vendor-portal` | 80 | Chef/vendor dashboard |
| `homechef-admin-portal` | `ghcr.io/tesserix/home-chef-app/homechef-admin-portal` | 80 | Platform admin panel |
| `homechef-delivery-portal` | `ghcr.io/tesserix/home-chef-app/homechef-delivery-portal` | 80 | Delivery partner dashboard |
| `homechef-auth-bff` | `ghcr.io/tesseract-nexus/global-services/auth-bff` | 8090 | Auth Backend-for-Frontend |

## Domains (Istio VirtualServices)

| Domain | Target |
|--------|--------|
| `fe3dr.com` / `www.fe3dr.com` | homechef-web |
| `vendors.fe3dr.com` | homechef-vendor-portal |
| `admin.fe3dr.com` | homechef-admin-portal |
| `delivery.fe3dr.com` | homechef-delivery-portal |
| `api.fe3dr.com` | homechef-api |
| `identity.fe3dr.com` | Keycloak customer realm |
| `internal-identity.fe3dr.com` | Keycloak internal realm |

### Route prefixes on `fe3dr.com`

- `/bff/` → auth-bff (customer realm)
- `/auth/` → Keycloak auth callback
- `/driver-bff/` → driver auth
- `/api/*` → API service
- `/ws/*` → WebSocket (3600s timeout)

## Infrastructure

- **PostgreSQL 16:** `postgresql.postgresql-homechef.svc.cluster.local:5432`,
  db `homechef_db`, 60Gi, 300 max connections
- **Redis:** `redis.redis-homechef.svc.cluster.local:6379`, 4Gi, auth enabled
  (session store)
- **Cloudflare Tunnel:** token from GCP Secret Manager
  (`prod-homechef-cloudflare-tunnel-token`)
- **External Secrets:** `homechef-api-secrets`, `homechef-auth-bff-secrets`
  synced from GCP Secret Manager
- **DB bootstrap CronJob:** every 30 min, idempotent schema provisioning
- **GCP SA:** `app-secrets-homechef-prod@tesseracthub-480811.iam.gserviceaccount.com`

## Auth (dual Keycloak)

- **Customer realm (`homechef`):** `identity.fe3dr.com` /
  `keycloak.identity-customer.svc.cluster.local:8080`
- **Internal realm (`tesserix-internal`):** `internal-identity.fe3dr.com` /
  `keycloak.identity-internal.svc.cluster.local:8080`
- Admin portal uses the internal realm; customer, vendor, and delivery use the
  customer realm.

For login/SSO debugging see [`internal-keycloak-admin-bff-fix.md`](internal-keycloak-admin-bff-fix.md)
(admin/internal) and [`customer-keycloak-social-login.md`](customer-keycloak-social-login.md)
(customer/social).

## Helm charts

All under `charts/apps/homechef-*`, with ArgoCD apps in
`argocd/prod/apps/homechef/`.

## E2E tests (Playwright)

**Location:** `homechef-e2e-tests/` (sibling of this repo, not committed here).

**TEMPORARY** — the test users and the project itself are for development and
debugging only, and must be removed before a production-ready release:

- Keycloak test user `e2e-test@fe3dr.com` in the `homechef` realm (customer)
- Keycloak test user `e2e-admin@fe3dr.com` in the `tesserix-internal` realm (admin)
- Firebase test phone `+91 650 555 3434` with OTP `654321` (mobile-app phone
  sign-in; configured as a fictional test number in Firebase Auth, no SMS sent)
- The `homechef-e2e-tests/` directory

### Login flow per portal

- **Web** (`fe3dr.com`): homepage → "Login" → "Sign in with email" → Keycloak form
- **Vendor** (`vendors.fe3dr.com`): login page auto-loads → "Sign in with Email" →
  Keycloak form
- **Admin** (`admin.fe3dr.com`): go to `/bff/login` → redirects to internal
  Keycloak → form login (BFF uses HttpOnly cookies, no `storageState`)
- **Delivery** (`delivery.fe3dr.com`): role selection ("I'm a Driver" / "I'm
  Staff") → email login → Keycloak form

### Commands

```bash
cd homechef-e2e-tests
npm test                    # all tests headless
npm run test:headed         # all tests with browser
npm run test:web            # web only
npm run test:vendor         # vendor only
npm run test:admin          # admin only
npm run test:delivery       # delivery only
npm run setup               # auth setup only
```

## Support (Otto live chat + tickets + staff queue)

- **Otto** (`support-platform-otto`) hosts live chat for tenants `homechef`
  (customers: fe3dr.com widget + mobile customer app) and `homechef-vendor`
  (chef app; homechef-api re-scopes chef-role callers). slm-router answers
  first from the RAG KB and flips `needs_human` to queue a person.
- **Knowledge base** — `charts/apps/support-platform-kb-seed/values.yaml`
  → `content.homechef` (audience metadata separates customer/chef/driver
  entries). The seed Job re-runs on any content change (configmap-hash job
  name); keep entries in sync with Home-Chef-App policy code.
- **Escalation → ticket**: slm-router `escalationHook` POSTs to homechef-api
  `/internal/support/tickets/from-conversation` (secret: SUPPORT_HOOK_SECRET
  from `prod-homechef-support-hook-secret`), idempotent on
  `support_tickets.conversation_id`.
- **Staff queue events**: otto publishes `otto.support.<tenant>.<event>`
  (created/escalated/accepted/closed) to shared NATS; homechef-api's SUPPORT
  stream consumer drives `SupportQueueWorkflow` (Temporal, notifications
  queue): immediate email to support@fe3dr.com, 3m reminder, 15m SLA breach.
  Real-time admin layer: tesserix-home `SupportQueueProvider` (toasts +
  Live chat sidebar badge from the platform inbox WS).
