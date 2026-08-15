# Cloudflare Zero Trust Tunnel Setup - Production (mark8ly.com)

This document describes the Cloudflare Tunnel configuration for the **production** environment using the `mark8ly.com` domain.

## Tunnel Details

| Property | Value |
|----------|-------|
| **Tunnel Name** | PROD_MARKETLY |
| **Tunnel ID** | `2b78323c-aa85-4b96-b703-c831357e7d33` |
| **Account ID** | `6fe6e1aa18c221b529ce76c9631ba4e0` |
| **Domain** | mark8ly.com |
| **Origin Service** | `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80` |

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   User/Client   │────▶│   Cloudflare    │────▶│   cloudflared   │────▶│  Istio Gateway  │
│                 │     │   (TLS Term)    │     │   (in-cluster)  │     │   (routing)     │
└─────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────────┘
                                                                                 │
                                                                                 ▼
                                                                        ┌─────────────────┐
                                                                        │    Services     │
                                                                        │  (marketplace,  │
                                                                        │   identity, etc)│
                                                                        └─────────────────┘
```

**Traffic Flow:**
1. User requests `https://admin.mark8ly.com`
2. Cloudflare terminates TLS and routes via tunnel
3. `cloudflared` pod receives request and forwards to Istio gateway
4. Istio Gateway routes based on Host header to appropriate VirtualService
5. VirtualService routes to backend service

## Automatic Onboarding (Self-Managed)

New services are **automatically onboarded** without any manual Cloudflare configuration. The system uses wildcard routing at multiple layers:

### How It Works

```
┌─────────────────────────────────────┐
│  1. Create VirtualService           │
│     host: new-service.mark8ly.com   │
└─────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│  2. external-dns detects it         │
│     (watches istio-virtualservice)  │
└─────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│  3. Creates DNS CNAME record:       │
│     new-service.mark8ly.com CNAME   │
│     2b78323c-...cfargotunnel.com    │
└─────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│  4. Cloudflare Tunnel matches       │
│     *.mark8ly.com wildcard route    │
└─────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│  5. Istio Gateway matches           │
│     *.mark8ly.com wildcard server   │
└─────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│  6. VirtualService routes to        │
│     backend service                 │
└─────────────────────────────────────┘
```

### Components Enabling Automation

| Component | Configuration | Purpose |
|-----------|--------------|---------|
| **Cloudflare Tunnel** | `*.mark8ly.com` wildcard ingress rule | Routes any subdomain to Istio |
| **Istio Gateway** | `*.mark8ly.com` HTTPS server | Accepts traffic for any subdomain |
| **Wildcard Certificate** | `*.mark8ly.com` via cert-manager | TLS for all subdomains |
| **external-dns** | Watches `istio-virtualservice` | Auto-creates DNS records |

### external-dns Configuration

```yaml
sources:
  - istio-virtualservice
  - istio-gateway
domainFilters:
  - mark8ly.com
extraArgs:
  - --default-targets=2b78323c-aa85-4b96-b703-c831357e7d33.cfargotunnel.com
```

### Adding a New Service

**No Cloudflare configuration needed!** Just create the VirtualService:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: new-service-vs
  namespace: marketplace
  labels:
    app.kubernetes.io/part-of: tesserix
spec:
  hosts:
    - "new-service.mark8ly.com"
  gateways:
    - istio-ingress/tesseract-gateway
  http:
    - route:
        - destination:
            host: new-service.marketplace.svc.cluster.local
            port:
              number: 8080
```

Within 1-2 minutes:
1. external-dns creates DNS CNAME pointing to tunnel
2. Traffic automatically flows through the tunnel
3. Wildcard TLS certificate covers the new subdomain

### Verify Automatic Setup

```bash
# Check DNS record was created
dig +short new-service.mark8ly.com

# Should return Cloudflare IPs (proxied)
# 172.67.165.103
# 104.21.81.227

# Check VirtualService exists
kubectl get virtualservice new-service-vs -n marketplace
```

## Configured Hostname Routes

All routes point to: `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80`

| Hostname | Service |
|----------|---------|
| `admin.mark8ly.com` | Admin Dashboard |
| `store.mark8ly.com` | Storefront |
| `onboard-your-store.mark8ly.com` | Tenant Onboarding |
| `api.mark8ly.com` | API Gateway |
| `identity.fanzonebattleground.com` | Customer IDP |
| `growthbook.mark8ly.com` | Feature Flags |
| `search.mark8ly.com` | Typesense Search |
| `postal.mark8ly.com` | Email (Postal) |
| `mautic.mark8ly.com` | Marketing (Mautic) |
| `fanzone.mark8ly.com` | FanZone |
| `hms-staff.mark8ly.com` | HMS Staff Portal |
| `hms-patient.mark8ly.com` | HMS Patient Portal |
| `api-docs.mark8ly.com` | API Documentation |
| `status-dashboard.mark8ly.com` | Status Dashboard |
| `*.mark8ly.com` | Wildcard (tenant storefronts) |

## Managing Tunnel Configuration

### Prerequisites

- Cloudflare API Token with permissions:
  - `Account:Cloudflare Tunnel:Edit`
  - `Zone:DNS:Edit` (for mark8ly.com zone)

The API token is stored in:
- **GCP Secret Manager**: `prod-cloudflare-api-token`
- **Kubernetes Secret**: `cloudflare-api-token` (in `cert-manager` namespace)

### Get Current Configuration

```bash
CF_TOKEN="<your-api-token>"
ACCOUNT_ID="6fe6e1aa18c221b529ce76c9631ba4e0"
TUNNEL_ID="2b78323c-aa85-4b96-b703-c831357e7d33"

curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/json" | jq .
```

### Update Configuration

```bash
CF_TOKEN="<your-api-token>"
ACCOUNT_ID="6fe6e1aa18c221b529ce76c9631ba4e0"
TUNNEL_ID="2b78323c-aa85-4b96-b703-c831357e7d33"

curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/json" \
  --data '{
    "config": {
      "ingress": [
        {
          "hostname": "admin.mark8ly.com",
          "service": "http://istio-ingressgateway.istio-ingress.svc.cluster.local:80",
          "originRequest": {
            "noTLSVerify": true
          }
        },
        {
          "hostname": "*.mark8ly.com",
          "service": "http://istio-ingressgateway.istio-ingress.svc.cluster.local:80",
          "originRequest": {
            "noTLSVerify": true
          }
        },
        {
          "service": "http_status:404"
        }
      ]
    }
  }'
```

### Add a New Hostname Route

To add a new hostname:

1. Get current configuration
2. Add new entry to the `ingress` array (before the wildcard and 404 catch-all)
3. PUT the updated configuration

Example adding `new-service.mark8ly.com`:

```json
{
  "hostname": "new-service.mark8ly.com",
  "service": "http://istio-ingressgateway.istio-ingress.svc.cluster.local:80",
  "originRequest": {
    "noTLSVerify": true
  }
}
```

**Note:** The order matters! More specific hostnames should come before wildcards.

## Cloudflared Deployment

The `cloudflared` connector runs in the `cloudflared` namespace:

```bash
# Check pods
kubectl get pods -n cloudflared

# Check logs
kubectl logs -n cloudflared -l app.kubernetes.io/name=cloudflared --tail=50

# Restart to pick up new configuration
kubectl rollout restart deployment cloudflared -n cloudflared
```

### Configuration Sync

Cloudflared automatically syncs configuration from Cloudflare. After updating via API:

1. Configuration is pushed to Cloudflare
2. Cloudflared pods receive update within ~30 seconds
3. You'll see in logs: `INF Updated to new configuration`

If needed, restart pods to force immediate sync:

```bash
kubectl rollout restart deployment cloudflared -n cloudflared
```

## DNS Configuration

DNS records for mark8ly.com are managed by:
- **Cloudflare DNS** (proxied through Cloudflare)
- **external-dns** (creates CNAME records pointing to tunnel)

DNS records point to Cloudflare's proxy (orange cloud enabled), which routes through the tunnel.

### Verify DNS

```bash
# Should return Cloudflare IPs (proxied)
dig +short admin.mark8ly.com
# Example: 172.67.165.103, 104.21.81.227
```

## Troubleshooting

### Site Returns 502 Bad Gateway

1. Check cloudflared logs:
   ```bash
   kubectl logs -n cloudflared -l app.kubernetes.io/name=cloudflared --tail=50
   ```

2. Verify Istio gateway is running:
   ```bash
   kubectl get pods -n istio-ingress
   ```

3. Test internal connectivity:
   ```bash
   kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
     curl -s -H "Host: admin.mark8ly.com" http://istio-ingressgateway.istio-ingress.svc.cluster.local
   ```

### Site Returns 503 Service Unavailable

1. Check tunnel configuration in Cloudflare dashboard
2. Verify cloudflared pods are running and connected
3. Check if tunnel token is valid

### Site Returns 404 Not Found

1. Verify VirtualService exists for the hostname:
   ```bash
   kubectl get virtualservices -A | grep <hostname>
   ```

2. Check Gateway has the hostname configured:
   ```bash
   kubectl get gateway -n istio-ingress -o yaml | grep <hostname>
   ```

### Connection Refused Errors

1. Verify the origin service URL in tunnel config
2. Check if Istio gateway pods are listening on port 80:
   ```bash
   kubectl exec -n istio-ingress <gateway-pod> -- netstat -tlnp | grep :80
   ```

## Related Documentation

- [Cloudflare Tunnel Docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Cloudflare API - Tunnel Configurations](https://developers.cloudflare.com/api/operations/cloudflare-tunnel-configuration-get-configuration)
- [Istio Gateway Configuration](../../../thirdparty/istio-config/README.md)

## Differences from DevTest

| Aspect | DevTest | Production |
|--------|---------|------------|
| Domain | tesserix.app | mark8ly.com |
| Tunnel | DEVTEST_TESSERIX | PROD_MARKETLY |
| Tunnel ID | (different) | 2b78323c-aa85-4b96-b703-c831357e7d33 |
| GCP Secret | devtest-cloudflare-tunnel-token | prod-cloudflare-tunnel-token |
