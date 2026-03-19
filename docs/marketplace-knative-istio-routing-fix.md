# Marketplace Knative + Istio Routing Fix — mark8ly.com

**Date:** 2026-03-19
**Affected Services:** marketplace-onboarding, marketplace-admin, mp-storefront
**Domain:** mark8ly.com, admin.mark8ly.com, store.mark8ly.com
**Root Cause:** Knative ExternalName services incompatible with Istio mTLS + Cloudflare Tunnel traffic flow
**Resolution:** Direct ClusterIP services bypassing Knative networking for ingress-routed frontends

---

## Symptom

Visiting `https://mark8ly.com` returned:

```
upstream connect error or disconnect/reset before headers. retried and the latest
reset reason: remote connection failure, transport failure reason:
TLS_error:|268435703:SSL routines:OPENSSL_internal:WRONG_VERSION_NUMBER:TLS_error_end
```

This was an Envoy/Istio error, not a browser-side TLS issue. The Cloudflare → origin connection was failing.

---

## Background Architecture

### Traffic Flow (Production)

```
Browser → Cloudflare CDN (TLS termination)
       → Cloudflare Tunnel (QUIC)
       → cloudflared pod (istio-ingress namespace)
       → http://istio-ingressgateway.istio-ingress.svc.cluster.local:80  (plain HTTP)
       → Istio Gateway (tesseract-gateway) on port 80
       → VirtualService routing based on Host header
       → Backend service
```

Key points:
- DNS for `mark8ly.com` resolves to Cloudflare IPs (`104.21.x.x`, `172.67.x.x`), NOT the GKE load balancer
- Cloudflare Tunnel sends **plain HTTP** to the internal `istio-ingressgateway` (ClusterIP)
- The `custom-ingressgateway` (LoadBalancer at `34.14.139.74`) is for custom domains, NOT mark8ly.com

### Two Ingress Gateways

| Component | Selector | Service Type | Purpose |
|-----------|----------|-------------|---------|
| `istio-ingressgateway` | `istio: ingressgateway` | ClusterIP | Platform domains (via Cloudflare Tunnel) |
| `custom-ingressgateway` | `istio: custom-ingressgateway` | LoadBalancer | Customer custom domains |
| `istio-ingressgateway-internal` | `istio: ingressgateway-internal` | ClusterIP (knative-local-gateway) | Knative internal routing |

### Knative Service Networking

When a Knative Service is created (e.g., `marketplace-onboarding`), Knative creates:

1. **ExternalName Service** (`marketplace-onboarding`) → resolves to `knative-local-gateway.istio-ingress.svc.cluster.local`
2. **Revision ClusterIP Services** (`marketplace-onboarding-00018`) → port 80, targetPort 8012 (queue-proxy)
3. **Private Revision Services** (`marketplace-onboarding-00018-private`) → includes sidecar stats ports
4. **VirtualServices** (`marketplace-onboarding-ingress`, `marketplace-onboarding-mesh`) → route internal traffic to the correct revision

The intended routing chain:
```
Client → ExternalName svc (marketplace-onboarding:80)
       → DNS resolves to knative-local-gateway.istio-ingress.svc.cluster.local
       → knative-local-gateway Envoy matches Knative ingress VS
       → Routes to marketplace-onboarding-00018:80 (targetPort 8012)
       → queue-proxy → Next.js app (port 3000)
```

---

## Issues Found and Fixed (in order)

### Issue 1: Cloud Run Routing Still Active

**Problem:** `values-prod.yaml` had `cloudRun.enabled: true`, causing all VirtualServices to route to Cloud Run services (e.g., `marketplace-tenant-onboarding-un6tyb5opq-el.a.run.app:443`) which had been shut down after migration to GKE Knative.

**Fix:**
- Set `cloudRun.enabled: false` in `values-prod.yaml`
- Set `cloudRunHostRewrite: []` (no longer needed)
- Removed all `{{- if .Values.cloudRun.enabled }}` / `{{- else }}` / `{{- end }}` conditional blocks from `virtual-services.yaml`, keeping only the GKE paths

**Files changed:**
- `charts/thirdparty/istio-config/values-prod.yaml`
- `charts/thirdparty/istio-config/templates/virtual-services.yaml`

### Issue 2: Service Name Mismatches

**Problem:** The VirtualService templates used old service names from the original deployment architecture. Knative services were created with different names.

**Mapping (old → new):**

| Template Name | Actual Knative Service |
|---------------|----------------------|
| `admin` | `marketplace-admin` |
| `storefront` | `mp-storefront` |
| `tenant-onboarding` | `marketplace-onboarding` |
| `products-service` | `mp-products` |
| `categories-service` | `mp-categories` |
| `orders-service` | `mp-orders` |
| `coupons-service` | `mp-coupons` |
| `staff-service` | `mp-staff` |
| `reviews-service` | `mp-reviews` |
| `vendor-service` | `mp-vendors` |
| `tax-service` | `mp-tax` |
| `payment-service` | `mp-payments` |
| `shipping-service` | `mp-shipping` |
| `customers-service` | `mp-customers` |
| `inventory-service` | `mp-inventory` |

Services that kept their names: `tenant-service`, `location-service`, `document-service`, `verification-service`, `tickets-service`, `notification-hub`, `notification-service`, `analytics-service`, `feature-flags-service`

**Fix:** Updated all service hostnames in `virtual-services.yaml`

### Issue 3: Port Mismatch (8080 → 80)

**Problem:** Backend service routes used port `8080` (the Go service container port). But Knative services expose port `80` at the service level (targetPort `8012` on the queue-proxy).

**Fix:** Changed all marketplace service ports from `8080` to `80`. Kept `8080` for non-marketplace services (Keycloak, HMS services).

### Issue 4: HTTP-to-HTTPS Redirect Loop

**Problem:** The `tesseract-gateway` had an HTTP server on port 80 with `httpsRedirect: true` for all platform domains including `mark8ly.com`. Since Cloudflare Tunnel sends plain HTTP, every request was redirected to HTTPS, which went through Cloudflare again → back to HTTP via tunnel → infinite redirect loop.

**Fix:** Replaced the per-domain HTTP server (with redirect) and the wildcard custom-domains HTTP server with a single HTTP server:

```yaml
servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
      - "*"
    # NO httpsRedirect - all traffic arrives via Cloudflare Tunnel
```

**File changed:** `charts/thirdparty/istio-config/templates/gateway.yaml`

### Issue 5: ArgoCD Project Missing Namespaces

**Problem:** The `infrastructure` ArgoCD project didn't have permissions for namespaces like `global`, `fanzone`, `homechef`, `bookkeeping`, `hms`, `tesserix`, `identity-customer`, `identity-internal`, and all `postgresql-*`, `redis-*`, `mongodb-*` namespaces. This caused the `istio-config` sync to fail with "namespace not permitted in project 'infrastructure'".

**Fix:** Added 21 missing namespaces to `argocd/prod/projects/infrastructure.yaml`:
- App namespaces: `global`, `tesserix`, `fanzone`, `homechef`, `hms`, `bookkeeping`
- Identity: `identity-customer`, `identity-internal`
- Databases: `postgresql-{global,marketplace,hms,fanzone,homechef,bookkeeping}`
- Redis: `redis-{marketplace,fanzone,homechef}`
- MongoDB: `mongodb-fanzone`
- Backup: `db-backup-and-restore`

### Issue 6: Knative ExternalName + Istio mTLS Incompatibility (ROOT CAUSE)

**Problem:** This was the core issue that took the longest to diagnose. The traffic chain:

```
Istio ingress gateway
  → marketplace-onboarding.marketplace.svc.cluster.local:80 (ExternalName)
  → DNS resolves to knative-local-gateway.istio-ingress.svc.cluster.local
  → knative-local-gateway receives request
  → knative-local-gateway routes to marketplace-onboarding-00018:80 (ClusterIP)
  → kube-proxy DNAT to pod_ip:8012
  → iptables redirect to pod_ip:15006 (istio-proxy sidecar)
  → sidecar terminates TLS → queue-proxy:8012 → Next.js:3000
```

The failure point was step 4→5→6. The `marketplace-services-dr` DestinationRule applied `ISTIO_MUTUAL` (mTLS) to `*.marketplace.svc.cluster.local`. When the knative-local-gateway's Envoy tried to connect to `marketplace-onboarding-00018:80` with mTLS, the TLS handshake failed with `WRONG_VERSION_NUMBER`.

**Why mTLS failed:** The knative-local-gateway (`istio-ingressgateway-internal`) pods are standalone Envoy proxies (1/1 container, no sidecar). Although they have Istio identity certs and should support mTLS, the connection to the backend pod's sidecar on port 8012 (redirected to 15006) was consistently failing. The exact cause appears to be related to how the internal gateway establishes mTLS connections to pods with Istio sidecars — the TLS handshake receives a plain HTTP response instead of a TLS ServerHello.

**Debugging evidence:**
- Direct `curl http://pod_ip:8012/` from the internal gateway → **200 OK** (bypasses Envoy, no mTLS)
- Direct `curl http://pod_ip:3000/` from the internal gateway → **200 OK** (bypasses everything)
- `curl http://ClusterIP:80/` from the internal gateway → **404** (works, no mTLS via Envoy)
- `curl http://service-name.marketplace.svc.cluster.local:80/` from the internal gateway → **timeout** (Envoy intercepts, applies mTLS, hangs)
- Setting `marketplace-services-dr` to `tls.mode: DISABLE` → connections work but Knative ingress VS routing still fails due to Host header mismatch

**Additional sub-issues within this:**

1. **`headers.request.set.Host` doesn't work in Istio VirtualService** — Envoy treats `Host`/`:authority` as a special header and ignores the `request_headers_to_add` directive for it. The Envoy config dump confirmed `request_headers_to_add` was empty.

2. **`rewrite.authority` works** — Using `rewrite: { authority: ... }` in the VirtualService correctly sets `host_rewrite_literal` in the Envoy route config.

3. **Even with correct authority rewrite, the knative-local-gateway couldn't reach the backend** — The connection from the internal gateway Envoy to the backend service timed out, even with `tls.mode: DISABLE`.

**Resolution:** Created direct ClusterIP Services that bypass the entire Knative ExternalName → knative-local-gateway chain:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: marketplace-onboarding-direct
  namespace: marketplace
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8012  # queue-proxy port
      protocol: TCP
      name: http
  selector:
    serving.knative.dev/service: marketplace-onboarding
```

The VirtualService routes directly to these services:

```yaml
- route:
    - destination:
        host: marketplace-onboarding-direct.marketplace.svc.cluster.local
        port:
          number: 80
```

This bypasses:
- Knative ExternalName service resolution
- knative-local-gateway Envoy routing
- Knative ingress VirtualService matching
- The mTLS issue between internal gateway and backend pods

The direct ClusterIP service uses label `serving.knative.dev/service: marketplace-onboarding` which matches ALL revisions, so traffic automatically routes to the latest pods regardless of revision number.

**Services created:**
- `marketplace-onboarding-direct` → for `mark8ly.com`
- `marketplace-admin-direct` → for `admin.mark8ly.com`
- `mp-storefront-direct` → for `store.mark8ly.com`

**Files changed:**
- `charts/thirdparty/istio-config/templates/virtual-services.yaml` (added Services + updated routes)
- `charts/thirdparty/istio-config/templates/destination-rules.yaml` (added TLS DISABLE DRs)

---

## Current State

### Working

- `mark8ly.com` → marketplace-onboarding (HTTP 200)
- All VirtualServices deployed via ArgoCD (Helm-managed)
- Let's Encrypt cert (`apex-domain-tls`) valid until May 6, 2026
- Cloudflare Tunnel → istio-ingressgateway → backend chain functional

### Known Limitations

1. **mTLS disabled for marketplace services** — `marketplace-services-dr` was changed from `ISTIO_MUTUAL` to `DISABLE`. This should be investigated and re-enabled once the root cause of the mTLS handshake failure between the knative-local-gateway and backend pods is resolved.

2. **Direct services bypass Knative features** — The `-direct` ClusterIP services bypass Knative's traffic management (canary deployments, revision splitting, scale-to-zero activation). However, Knative still manages the deployments and pod lifecycle. The pods are already running via Knative, we're just using a different service to reach them.

3. **Backend API services still route through Knative ExternalName** — Only the frontend services (onboarding, admin, storefront) have `-direct` services. Backend Go services (mp-products, mp-orders, etc.) are routed from the frontend VS through the Knative ExternalName chain. These currently work because `marketplace-services-dr` has `tls.mode: DISABLE`.

4. **NetworkPolicies now deployed** — The ArgoCD sync deployed `default-deny-ingress` + `allow-marketplace-ingress` NetworkPolicies to the marketplace namespace. These allow traffic from `istio-ingress`, `marketplace`, `global`, `tesserix`, `monitoring`, `istio-system`, and `kube-system` namespaces.

---

## Future Action Items

1. **Investigate mTLS failure** — Determine why `istio-ingressgateway-internal` pods cannot establish mTLS connections to marketplace pods with Istio sidecars. Check:
   - Istio version compatibility between gateway and sidecar
   - Certificate rotation / expiry on internal gateway pods
   - iptables rules on marketplace pods (confirm port 8012 redirects to 15006)
   - Envoy access logs on both sides during mTLS handshake

2. **Re-enable ISTIO_MUTUAL** — Once mTLS works, change `marketplace-services-dr` back to `ISTIO_MUTUAL` and remove the per-service `tls.mode: DISABLE` DRs.

3. **Create `-direct` services for backend APIs** — If mTLS can't be fixed, create direct services for all backend Knative services too (mp-products, mp-orders, etc.).

4. **Consider removing Knative for frontends** — The frontend apps (onboarding, admin, storefront) don't benefit much from Knative's scale-to-zero since they need to be always-available. Regular Deployments + Services would be simpler and avoid the ExternalName routing chain entirely.

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `charts/thirdparty/istio-config/templates/gateway.yaml` | Istio Gateway (HTTP/HTTPS servers, TLS certs) |
| `charts/thirdparty/istio-config/templates/virtual-services.yaml` | All VirtualService routes + direct ClusterIP services |
| `charts/thirdparty/istio-config/templates/destination-rules.yaml` | Traffic policies, mTLS settings, circuit breakers |
| `charts/thirdparty/istio-config/values-prod.yaml` | Production overrides (domain, subdomains, CORS) |
| `charts/infrastructure/custom-domain-gateway/` | Custom domain gateway (separate from platform) |
| `charts/infrastructure/cloudflared/` | Cloudflare Tunnel deployment |
| `argocd/prod/projects/infrastructure.yaml` | ArgoCD project permissions |
| `argocd/prod/infrastructure/istio-config.yaml` | ArgoCD app for istio-config chart |

## Useful Debug Commands

```bash
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
export KUBECONFIG=~/.kube/gke-prod
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

# Check Knative services
kubectl get ksvc -n marketplace

# Check VirtualServices for mark8ly
kubectl get virtualservice -n marketplace | grep mark8ly

# Check gateway config
kubectl get gateway tesseract-gateway -n istio-ingress -o yaml

# Check DRs
kubectl get destinationrule -n marketplace

# Test from ingress gateway
POD=$(kubectl get pod -n istio-ingress -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n istio-ingress $POD 18080:80
curl -H "Host: mark8ly.com" http://localhost:18080/

# Check Envoy route config
kubectl exec -n istio-ingress $POD -- pilot-agent request GET config_dump | python3 -c "..."

# Check cloudflared tunnel logs
kubectl logs -n cloudflared -l app.kubernetes.io/name=cloudflared --tail=50

# ArgoCD sync
kubectl patch application istio-config -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD","syncStrategy":{"hook":{}}}}}'
```
