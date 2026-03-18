# Kubernetes API Network Policy Fix

## Issue Summary

**Error**: `dial tcp 10.30.0.1:443: i/o timeout` when tenant-router-service tried to create VirtualServices

**Root Cause**: The network policy `allow-marketplace-egress` was blocking access to the GKE control plane endpoint (`172.16.0.2`) which is the actual backend of the kubernetes service ClusterIP (`10.30.0.1`).

## Affected Services

- `tenant-router-service` - Unable to create/manage Kubernetes resources:
  - Certificates (cert-manager)
  - VirtualServices (Istio)
  - Gateway patches

## Symptoms

1. Tenant onboarding would complete account setup but fail to create VirtualServices
2. New tenant URLs (e.g., `your-store-admin.tesserix.app`) would return 404
3. tenant-router-service logs showed:
   ```
   failed to create certificate: Post "https://10.30.0.1:443/apis/cert-manager.io/v1/namespaces/marketplace/certificates": dial tcp 10.30.0.1:443: i/o timeout
   ```

## Technical Analysis

### Kubernetes Service Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GKE Cluster                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Pod (tenant-router-service)                                     │
│       │                                                          │
│       │ kubectl/client-go request                                │
│       ▼                                                          │
│  ┌─────────────────────┐                                         │
│  │ kubernetes service  │  ClusterIP: 10.30.0.1:443              │
│  │ (default namespace) │                                         │
│  └─────────┬───────────┘                                         │
│            │                                                     │
│            │ kube-proxy DNAT                                     │
│            ▼                                                     │
│  ┌─────────────────────┐                                         │
│  │ GKE Control Plane   │  Endpoint: 172.16.0.2:443              │
│  │ (API Server)        │                                         │
│  └─────────────────────┘                                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Network Policy Issue

The egress policy for marketplace namespace had:

```yaml
# Allow external HTTPS (for external APIs like Stripe, SendGrid, etc)
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8      # Blocks internal IPs
          - 172.16.0.0/12   # ❌ BLOCKS GKE CONTROL PLANE!
          - 192.168.0.0/16  # Blocks private IPs
  ports:
    - protocol: TCP
      port: 443
```

The `172.16.0.0/12` exception blocked the GKE control plane at `172.16.0.2`.

### Why ipBlock for 10.30.0.1 Didn't Work

Network policies are evaluated AFTER kube-proxy performs DNAT. So:
1. Pod sends request to `10.30.0.1:443`
2. kube-proxy DNATs to `172.16.0.2:443`
3. Network policy evaluates against `172.16.0.2:443`
4. The `172.16.0.0/12` exception blocks the traffic

## Resolution

### Changes Made

Updated `charts/thirdparty/istio-config/templates/network-policies.yaml`:

```yaml
# Allow access to Kubernetes API server
# Use namespaceSelector for the default namespace where kubernetes service lives
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: default
  ports:
    - protocol: TCP
      port: 443

# Also allow ipBlock for direct API server access (GKE control plane)
- to:
    - ipBlock:
        cidr: 10.30.0.1/32
  ports:
    - protocol: TCP
      port: 443

# Allow GKE control plane API server (actual endpoint behind kubernetes service)
# This is required because traffic to ClusterIP gets DNAT'd to control plane IP
- to:
    - ipBlock:
        cidr: 172.16.0.0/12
  ports:
    - protocol: TCP
      port: 443
```

### Manual Patch Applied

```bash
kubectl patch networkpolicy allow-marketplace-egress -n marketplace \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/egress/-", "value": {"to": [{"ipBlock": {"cidr": "172.16.0.0/12"}}], "ports": [{"protocol": "TCP", "port": 443}]}}]'
```

## Verification

### Check K8s API Access
```bash
# From tenant-router-service pod
kubectl exec -n marketplace -l app.kubernetes.io/name=tenant-router-service -- \
  timeout 5 nc -zv 10.30.0.1 443

# Expected: Connection succeeded
```

### Check VirtualService Creation
```bash
# Trigger provisioning
curl -X POST http://localhost:18089/api/v1/hosts \
  -H "Content-Type: application/json" \
  -d '{"slug": "test-store", "tenant_id": "test-tenant"}'

# Check VirtualServices created
kubectl get virtualservice -n marketplace | grep test-store
```

### Check tenant-router-service Logs
```bash
kubectl logs -n marketplace -l app.kubernetes.io/name=tenant-router-service \
  -c tenant-router-service --tail=50

# Look for:
# [Reconciler] Worker X: successfully reconciled test-store in Xms
```

## Prevention

### GKE Control Plane Considerations

When writing network policies for GKE:
1. The kubernetes service ClusterIP (`10.30.0.1`) is NOT the actual API server
2. Traffic gets DNAT'd to the control plane IP (often in `172.16.0.0/12`)
3. Network policies evaluate against the DNAT'd destination
4. Always allow the control plane CIDR for services that need K8s API access

### Recommended Pattern

```yaml
# For pods that need K8s API access (controllers, operators, etc.)
egress:
  # Allow kubernetes service (pre-DNAT)
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: default
    ports:
      - protocol: TCP
        port: 443
  # Allow GKE control plane (post-DNAT)
  - to:
      - ipBlock:
          cidr: 172.16.0.0/12
    ports:
      - protocol: TCP
        port: 443
```

## Related Issues

- GCS Storage Access Permissions: `issues/gcs-storage-access-permissions.md`
- Network Policies Cross-Namespace Access: `issues/network-policies-cross-namespace-access.md`

## Commits

1. `cf12b85` - `fix(network-policy): allow GKE control plane API access`

---

*Last Updated: 2026-01-08*
