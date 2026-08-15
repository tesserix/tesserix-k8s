# Cloudflare Zero Trust Tunnel Setup

This document describes how to configure Cloudflare Tunnel for Tesserix.

## Prerequisites

1. Cloudflare account with Zero Trust enabled
2. Domain(s) added to Cloudflare (tesserix.app)
3. Tunnel created in Cloudflare Zero Trust Dashboard

## Tunnel Configuration in Cloudflare Dashboard

### Step 1: Access Zero Trust Dashboard

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/)
2. Navigate to **Networks → Tunnels**
3. Find your tunnel (the one corresponding to the token)

### Step 2: Configure Public Hostname Routes

Add the following public hostname routes pointing to the Istio ingress gateway:

#### Wildcard Route (for tenant storefronts)
- **Public hostname:** `*.tesserix.app`
- **Service type:** HTTP
- **URL:** `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80`
- **Additional settings:**
  - No TLS verification (internal service)
  - HTTP Host Header: Pass through

#### Admin Dashboard
- **Public hostname:** `admin.tesserix.app`
- **Service type:** HTTP
- **URL:** `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80`

#### API Gateway
- **Public hostname:** `api.tesserix.app`
- **Service type:** HTTP
- **URL:** `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80`

#### Customer IDP
- **Public hostname:** `devtest-customer-idp.tesserix.app`
- **Service type:** HTTP
- **URL:** `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80`

#### Tenant Onboarding
- **Public hostname:** `onboarding.tesserix.app`
- **Service type:** HTTP
- **URL:** `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80`

#### GrowthBook Feature Flags
- **Public hostname:** `growthbook.tesserix.app`
- **Service type:** HTTP
- **URL:** `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80`

#### API Documentation
- **Public hostname:** `api-docs.tesserix.app`
- **Service type:** HTTP
- **URL:** `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80`

## DNS Configuration

Once the tunnel is running and routes are configured:

1. Go to Cloudflare DNS for tesserix.app
2. Update existing DNS records to use the tunnel:
   - Change A records to CNAME records pointing to the tunnel
   - Format: `<tunnel-uuid>.cfargotunnel.com`

Example:
```
admin.tesserix.app    CNAME   <tunnel-uuid>.cfargotunnel.com
api.tesserix.app      CNAME   <tunnel-uuid>.cfargotunnel.com
*.tesserix.app        CNAME   <tunnel-uuid>.cfargotunnel.com
```

## Verifying the Setup

1. Deploy cloudflared to the cluster:
   ```bash
   # Sync via ArgoCD or manual:
   kubectl get pods -n cloudflared
   ```

2. Check tunnel status in Cloudflare Dashboard:
   - Navigate to Networks → Tunnels
   - Verify tunnel shows as "Healthy"

3. Test connectivity:
   ```bash
   curl -v https://admin.tesserix.app
   ```

## Transition Plan

### Phase 1: Parallel Operation (Current)
- Keep LoadBalancer on Istio ingress
- Deploy cloudflared
- Configure routes in Cloudflare
- Test via CF tunnel (using CNAME records)

### Phase 2: Switch DNS
- Update DNS to point to tunnel
- Monitor traffic

### Phase 3: Remove LoadBalancer
- Change Istio ingress to ClusterIP
- Remove external-dns annotation
- Delete LoadBalancer public IP

## Troubleshooting

### Check cloudflared logs
```bash
kubectl logs -n cloudflared -l app.kubernetes.io/name=cloudflared -f
```

### Check tunnel metrics
```bash
kubectl port-forward -n cloudflared svc/cloudflared 2000:2000
curl localhost:2000/metrics
```

### Verify ExternalSecret
```bash
kubectl get externalsecret -n cloudflared
kubectl get secret cloudflare-tunnel-token -n cloudflared
```
