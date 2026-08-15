# Cloudflare Zero Trust Tunnel Setup — HomeChef (fe3dr.com)

Companion to `CLOUDFLARE_SETUP_PROD.md`. Same architecture, separate tunnel
because homechef is a distinct project with its own GCP secret.

## Tunnel Details

| Property | Value |
|----------|-------|
| **Tunnel Name** | `homechef-prod` (cloudflared chart release: `cloudflared-homechef`) |
| **Tunnel ID** | `03e498ae-dad7-4e6a-9744-6fa782956861` |
| **Account ID** | `6fe6e1aa18c221b529ce76c9631ba4e0` |
| **Domain** | `fe3dr.com` |
| **Origin Service** | `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80` |

Tunnel ID was decoded from the GCP secret `prod-homechef-cloudflare-tunnel-token`
(the token is base64-encoded JSON containing `t` = tunnel UUID).

## Required Cloudflare Tunnel Public Hostnames

These must be configured in the Cloudflare Zero Trust dashboard (this is **not**
managed by the helm chart — the chart only runs the cloudflared daemon; the
public hostname routing is part of the tunnel configuration in the Cloudflare
control plane).

| Hostname | Service |
|----------|---------|
| `fe3dr.com` | `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80` |
| `*.fe3dr.com` | `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80` |

The Istio Gateway then routes by `Host` header to the right per-portal
VirtualService:

| Hostname | Routes To |
|----------|-----------|
| `fe3dr.com`, `www.fe3dr.com` | `homechef-web` SPA |
| `vendors.fe3dr.com` | `homechef-vendor-portal` SPA |
| `admin.fe3dr.com` | `homechef-admin-portal` SPA |
| `delivery.fe3dr.com` | `homechef-delivery-portal` SPA |
| `api.fe3dr.com` | `homechef-api` |
| `identity.fe3dr.com` | `homechef-auth-bff` (Google Identity Platform) |
| `analytics.fe3dr.com` | `homechef-analytics` (when enabled) |

## DNS — automated by external-dns

DNS records for `fe3dr.com` and its subdomains are created automatically by
`external-dns` watching Istio VirtualServices in the `homechef` namespace.

**Required configuration (already applied):**

1. `argocd/prod/infrastructure/external-dns.yaml` — `domainFilters` includes
   `fe3dr.com`.
2. Each homechef VirtualService in `manifests/homechef-istio/virtualservice.yaml`
   carries the annotation:
   ```yaml
   metadata:
     annotations:
       external-dns.alpha.kubernetes.io/target: "03e498ae-dad7-4e6a-9744-6fa782956861.cfargotunnel.com"
       external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"
   ```

This per-VirtualService annotation **overrides** the global
`--default-targets=2b78323c-aa85-4b96-b703-c831357e7d33.cfargotunnel.com`
(which is mark8ly's tunnel) so each homechef record CNAMEs to the correct
homechef tunnel.

## Verification

```bash
# Check that the records exist (after external-dns syncs, ~1-2 min):
dig +short fe3dr.com           # → CNAME 03e498ae-...cfargotunnel.com (or A via proxy)
dig +short admin.fe3dr.com     # → same
dig +short api.fe3dr.com       # → same

# external-dns logs:
kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=50 | grep fe3dr
```

If records do not appear:
1. Confirm the Cloudflare API token in GCP secret `cloudflare-api-token` has
   `Zone:DNS:Edit` permission on the `fe3dr.com` zone.
2. Confirm `domainFilters` in `external-dns.yaml` includes `fe3dr.com`.
3. Confirm the homechef VirtualServices have the `target` annotation.
4. Force a sync: `kubectl -n external-dns rollout restart deployment external-dns`
   (read-only investigation only — let ArgoCD self-heal in steady state).
