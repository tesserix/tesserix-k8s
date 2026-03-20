# Marketplace Storefront Tenant Routing Fix — *.mark8ly.com

**Date:** 2026-03-20
**Affected Services:** mp-storefront, mp-vendors, tenant-router-service, all marketplace backend services
**Domain:** *.mark8ly.com (tenant subdomain routing)
**Root Cause:** Cloudflare Worker `tesserix-router` intercepting all wildcard subdomain traffic before tunnel
**Resolution:** Removed legacy Worker route, fixed Knative ExternalName mTLS issues, configured direct ClusterIP services

---

## Symptom

Visiting `https://test-app.mark8ly.com` (or any tenant subdomain) returned:

```
Tenant not found
```

Plain text 404 response with no HTML page. The onboarding flow created the tenant successfully but the storefront was unreachable.

---

## Architecture: Tenant Subdomain Routing

### Expected Traffic Flow

```
Browser → Cloudflare CDN (TLS termination)
       → Cloudflare Tunnel (QUIC)
       → cloudflared pod → http://istio-ingressgateway:80
       → Istio Gateway (tesseract-gateway) port 80
       → VirtualService (storefront-wildcard-vs) matches *.mark8ly.com
       → mp-storefront-direct ClusterIP Service
       → mp-storefront pod (Next.js)
       → Middleware extracts tenant slug from Host header
       → Resolves tenant via tenant-router-service
       → Resolves storefront via mp-vendors (public endpoint)
       → Fetches products/categories from backend services
       → Renders HTML page
```

### DNS Setup

```
*.mark8ly.com  → CNAME → mark8ly.com (proxied via Cloudflare)
mark8ly.com    → CNAME → 2b78323c-aa85-4b96-b703-c831357e7d33.cfargotunnel.com (Cloudflare Tunnel)
```

### Cloudflare Tunnel Config

The tunnel has `*.mark8ly.com → http://istio-ingressgateway.istio-ingress.svc.cluster.local:80` configured alongside 24 other specific hostname routes.

---

## Issues Found and Fixed (in order of discovery)

### Issue 1: Missing Wildcard VirtualService

**Problem:** No VirtualService existed for `*.mark8ly.com` to route tenant subdomain traffic to the storefront.

**Fix:** Created `storefront-wildcard-vs` and `admin-wildcard-vs` in the istio-config Helm chart:

```yaml
# storefront-wildcard-vs routes *.mark8ly.com → mp-storefront-direct
# admin-wildcard-vs routes *-admin.mark8ly.com → marketplace-admin-direct
```

**File:** `charts/thirdparty/istio-config/templates/virtual-services.yaml`

### Issue 2: Knative ExternalName mTLS Incompatibility

**Problem:** ALL Knative services create ExternalName K8s services that resolve to `knative-local-gateway.istio-ingress.svc.cluster.local`. When any service tried to call another service via these ExternalName services, the Istio sidecar applied mTLS which failed with `WRONG_VERSION_NUMBER` because the knative-local-gateway doesn't accept mTLS from mesh peers.

**Fix:** Created `-direct` ClusterIP services for ALL marketplace Knative services. These bypass the Knative ExternalName chain entirely by selecting pods directly via `serving.knative.dev/service` label:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mp-products-direct
spec:
  type: ClusterIP
  ports:
    - port: 8080
      targetPort: 8080
  selector:
    serving.knative.dev/service: mp-products
```

**Services created:** `mp-products-direct`, `mp-categories-direct`, `mp-orders-direct`, `mp-payments-direct`, `mp-shipping-direct`, `mp-coupons-direct`, `mp-customers-direct`, `mp-reviews-direct`, `mp-inventory-direct`, `mp-marketing-direct`, `mp-gift-cards-direct`, `mp-approvals-direct`, `mp-content-direct`, `mp-connector-direct`, `mp-tax-direct`, `mp-vendors-direct`, `mp-staff-direct`, `tickets-service-direct`, `analytics-service-direct`, `audit-service-direct`, `document-service-direct`, `feature-flags-service-direct`, `qr-service-direct`, `status-service-direct`, `subscription-service-direct`, `marketplace-onboarding-direct`, `marketplace-admin-direct`, `mp-storefront-direct`, `verification-service-direct`, `tenant-service-direct`, `location-service-direct`, `tenant-router-service-direct`, `notification-service-direct`

### Issue 3: h2UpgradePolicy Protocol Error

**Problem:** The `marketplace-services-dr` DestinationRule had `h2UpgradePolicy: UPGRADE` which upgraded HTTP/1.1 connections to HTTP/2. Some Go services (particularly `tenant-router-service` on port 8089) don't support HTTP/2, causing `protocol error` responses.

**Fix:** Changed to `h2UpgradePolicy: DO_NOT_UPGRADE` in the marketplace-services-dr:

```yaml
spec:
  host: "*.marketplace.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: DISABLE
    connectionPool:
      http:
        h2UpgradePolicy: DO_NOT_UPGRADE  # was UPGRADE
```

**File:** `charts/thirdparty/istio-config/templates/destination-rules.yaml`

### Issue 4: Missing Service URLs in Storefront Config

**Problem:** The `mp-storefront` Helm chart had no `env` section in `values-prod.yaml`, causing all service URLs to use development defaults (localhost). The storefront couldn't reach any backend services.

**Fix:** Added all required service URLs to `values-prod.yaml`:

```yaml
env:
  PRODUCTS_SERVICE_URL: "http://mp-products-direct.marketplace.svc.cluster.local:8080/api/v1"
  CATEGORIES_SERVICE_URL: "http://mp-categories-direct.marketplace.svc.cluster.local:8080/api/v1"
  VENDORS_SERVICE_URL: "http://mp-vendors-direct.marketplace.svc.cluster.local:8080/api/v1"
  TENANT_ROUTER_SERVICE_URL: "http://tenant-router-service-direct.marketplace.svc.cluster.local:8089"
  # ... 15+ more service URLs
```

**Important:** The env var is `VENDORS_SERVICE_URL` (plural, not `VENDOR_SERVICE_URL`). The products/categories URLs need `/api/v1` suffix because the storefront code appends `/storefront/products` (the public endpoint path is `/api/v1/storefront/products`).

### Issue 5: Storefront Public vs Protected API Endpoints

**Problem:** The storefront tried to call `/api/v1/products` (protected, requires auth + OpenFGA) instead of `/api/v1/storefront/products` (public, tenant-context only).

**Finding:** The storefront code already uses the correct public path (`/storefront/products`), but the `PRODUCTS_SERVICE_URL` env var needs to include `/api/v1` so the full URL becomes `http://mp-products-direct:8080/api/v1/storefront/products`.

### Issue 6: Vendor Storefront Resolve 403

**Problem:** The wildcard VS routed `/api/v1/storefronts/resolve` to `mp-vendors-direct` but the vendor-service's OpenFGA middleware returned 403 "FORBIDDEN: User context not found" because there's no authenticated user for storefront resolution.

**Fix:** The vendor-service has a separate **public** endpoint at `/api/v1/public/storefronts/resolve/by-slug/:slug` that doesn't require auth. The storefront code already uses this path. The VS was updated to also route `/api/v1/public/storefronts` to mp-vendors-direct.

### Issue 7: Tenant Not Registered in tenant-router-service

**Problem:** After onboarding creates a tenant, the `tenant_hosts` table in `tenant_router_db` was empty — the provisioning flow was interrupted before it could register the tenant's host mapping.

**Fix:** Manually inserted the tenant host record. The provisioning flow should do this automatically when account setup completes successfully. Schema was applied from migrations.

### Issue 8: All Marketplace DB Passwords Had Trailing Newlines

**Problem:** ALL GCP Secret Manager secrets for marketplace service DB passwords (15 services) had trailing `\n` (newline) characters. This caused:
- Go services using `pgx` (URL-based connection): `invalid control character in URL`
- Go services using `pgconn` (host-based): `password authentication failed` (because `password\n` != `password`)

**Fix:** Updated all 15 secrets in GCP Secret Manager with `echo -n` (no newline):

```bash
echo -n "$CORRECT_PASSWORD" | gcloud secrets versions add prod-mp-products-db-password \
  --project=tesseracthub-480811 --data-file=-
```

**Affected secrets:** `prod-mp-products-db-password`, `prod-mp-categories-db-password`, `prod-mp-orders-db-password`, `prod-mp-payments-db-password`, `prod-mp-shipping-db-password`, `prod-mp-coupons-db-password`, `prod-mp-customers-db-password`, `prod-mp-reviews-db-password`, `prod-mp-inventory-db-password`, `prod-mp-marketing-db-password`, `prod-mp-gift-cards-db-password`, `prod-mp-approvals-db-password`, `prod-mp-content-db-password`, `prod-mp-connector-db-password`, `prod-mp-tax-db-password`, `prod-mp-staff-db-password`, `prod-mp-vendors-db-password`

### Issue 9: Old Knative Revisions Serving Stale Config

**Problem:** When configmaps were updated and new Knative revisions created, old revisions with `minScale: 1` kept running. The `-direct` ClusterIP services selected ALL revisions (matching `serving.knative.dev/service=<name>`), causing ~50% of requests to hit old pods with stale config.

**Fix:** Deleted old revisions after new ones were confirmed working:

```bash
kubectl delete revision mp-storefront-00018 -n marketplace
```

**Long-term fix needed:** Either configure Knative to auto-delete old revisions (`revisionHistoryLimit`), or update the `-direct` services to select only the latest ready revision.

### Issue 10: Cloudflare Worker Intercepting Wildcard Traffic (ROOT CAUSE)

**Problem:** A Cloudflare Worker named `tesserix-router` with route `*.mark8ly.com/*` was intercepting ALL wildcard subdomain traffic at the Cloudflare edge. This Worker attempted to resolve tenants and returned "Tenant not found" — the request never reached the Cloudflare Tunnel or the origin server.

**Discovery:** Found via Cloudflare API:

```bash
curl -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/workers/routes"
# Result: {"pattern": "*.mark8ly.com/*", "script": "tesserix-router"}
```

**Fix:** Deleted the Workers route via API:

```bash
curl -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/workers/routes/$ROUTE_ID"
```

The `tesserix-router` Worker was a legacy edge-routing layer that has been fully replaced by:
1. Cloudflare Tunnel → GKE ingress gateway
2. Istio VirtualService wildcard routing
3. Next.js middleware tenant resolution
4. tenant-router-service for slug → tenant mapping
5. mp-vendors public endpoint for storefront resolution

---

## Current Architecture (After Fix)

```
Browser → https://test-app.mark8ly.com
       → Cloudflare CDN (TLS, no Worker intercept)
       → Cloudflare Tunnel (*.mark8ly.com route)
       → cloudflared pod → istio-ingressgateway:80
       → Gateway HTTP server (hosts: ["*"])
       → storefront-wildcard-vs (hosts: ["*.mark8ly.com"])
       → mp-storefront-direct:80 (ClusterIP → queue-proxy:8012)
       → Next.js middleware:
           1. Extracts "test-app" slug from Host header
           2. Calls tenant-router-service-direct:8089/api/v1/hosts/test-app
           3. Sets x-tenant-slug, x-tenant-id headers
       → Next.js layout.tsx:
           1. resolveStorefront() → mp-vendors-direct:8080/api/v1/public/storefronts/resolve/by-slug/test-app
           2. Parallel data fetch: products, categories, theme, localization
       → Renders HTML page: "Test App Store"
```

---

## Key Configuration Files

| File | Purpose |
|------|---------|
| `charts/thirdparty/istio-config/templates/virtual-services.yaml` | Wildcard VS, direct ClusterIP services |
| `charts/thirdparty/istio-config/templates/destination-rules.yaml` | mTLS DISABLE, h2UpgradePolicy DO_NOT_UPGRADE |
| `charts/apps/mp-storefront/values-prod.yaml` | All service URLs, BASE_DOMAIN |
| `charts/apps/mp-staff/values-prod.yaml` | OpenFGA store IDs |
| `charts/apps/mp-vendors/values-prod.yaml` | OpenFGA store IDs, STOREFRONT_DOMAIN |
| `charts/apps/marketplace-admin/values-prod.yaml` | minScale: 1 |

## Useful Debug Commands

```bash
# Check Cloudflare Workers routes
CF_TOKEN=$(gcloud secrets versions access latest --secret=DEBUG_CF --project=tesseracthub-480811)
curl -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/396425160cf0c851c83dd9f8699c502c/workers/routes"

# Purge Cloudflare cache for a subdomain
curl -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d '{"hosts":["test-app.mark8ly.com"]}' \
  "https://api.cloudflare.com/client/v4/zones/396425160cf0c851c83dd9f8699c502c/purge_cache"

# Test storefront from inside the pod
kubectl exec -n marketplace $SPOD -c app -- node -e "
fetch('http://localhost:3000/', {headers: {'Host': 'test-app.mark8ly.com'}, signal: AbortSignal.timeout(15000)})
  .then(r => console.log('Status:', r.status))
  .catch(e => console.log('Error:', e.message))
"

# Test via ingress gateway (bypasses Cloudflare)
kubectl port-forward -n istio-ingress $(kubectl get pod -n istio-ingress -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}') 18080:80
curl -H "Host: test-app.mark8ly.com" http://localhost:18080/

# Check which revision serves a -direct service
kubectl get endpoints mp-storefront-direct -n marketplace
kubectl get pods -n marketplace -l serving.knative.dev/service=mp-storefront -o wide

# Delete old Knative revisions
kubectl get revisions -n marketplace -l serving.knative.dev/service=mp-storefront
kubectl delete revision mp-storefront-00018 -n marketplace
```

## Lessons Learned

1. **Always check Cloudflare Workers routes** when debugging "origin not reached" issues. Workers execute before tunnels.
2. **Knative ExternalName services don't work with Istio mTLS** — always create `-direct` ClusterIP services.
3. **GCP secrets with trailing newlines** break Go database connections silently. Always use `echo -n`.
4. **h2UpgradePolicy: UPGRADE** breaks non-HTTP/2 services. Use `DO_NOT_UPGRADE` for mixed environments.
5. **Old Knative revisions with minScale>0** keep running and receive traffic via label-based selectors. Delete them after confirming new revision works.
6. **Service URL env vars need correct API path prefixes** — check the actual Go service route groups (e.g., `/api/v1/storefront/products` vs `/api/v1/products`).
