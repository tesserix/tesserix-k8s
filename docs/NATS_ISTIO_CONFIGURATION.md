# NATS and Istio Service Mesh Configuration

## Overview

This document describes the configuration required to ensure NATS JetStream works correctly with Istio service mesh in the Tesseract Hub platform.

## Problem Statement

When running NATS with Istio service mesh, the Istio sidecar proxy (Envoy) intercepts all network traffic by default. This causes issues with NATS JetStream operations:

- **Stream creation timeouts**: JetStream streams fail to create due to connection timeouts
- **Subscription failures**: Durable subscriptions cannot be established
- **Connection drops**: NATS connections intermittently fail

### Error Symptoms

```
[NATS] Failed to create stream: context deadline exceeded
[NATS] Error subscribing to events: nats: timeout
```

## Solution

Exclude NATS port 4222 from the Istio sidecar proxy using the `traffic.sidecar.istio.io/excludeOutboundPorts` annotation.

### Required Pod Annotations

All services using NATS must include these annotations in their `values.yaml`:

```yaml
podAnnotations:
  # Istio sidecar configuration - wait for proxy before starting app
  proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
  # Exclude NATS port from Istio sidecar to fix JetStream timeout issues
  traffic.sidecar.istio.io/excludeOutboundPorts: "4222"
```

### Explanation

| Annotation | Purpose |
|------------|---------|
| `proxy.istio.io/config` | Ensures the Istio proxy is ready before the application starts, preventing race conditions |
| `traffic.sidecar.istio.io/excludeOutboundPorts: "4222"` | Bypasses Istio proxy for NATS traffic, allowing direct TCP connections |

## Services Requiring This Configuration

Any service that connects to NATS requires this annotation. Current services include:

### Marketplace Services
- auth-service
- categories-service
- coupons-service
- customers-service
- gift-cards-service
- inventory-service
- marketing-service
- marketplace-connector-service
- notification-hub
- notification-service
- orders-service
- payment-service
- products-service
- reviews-service
- shipping-service
- vendor-service
- tenant-service
- tenant-router-service
- tenant-onboarding
- audit-service
- approval-service

### Bookkeeping Services
- bookkeeping-auth-service
- bookkeeping-core-service
- bookkeeping-customer-service
- bookkeeping-invoice-service
- bookkeeping-report-service
- bookkeeping-tax-service

### HMS (Hospital Management) Services
- hms-appointment-service
- hms-auth-service
- hms-billing-service
- hms-crm-service
- hms-gateway
- hms-international-patient-service
- hms-patient-service
- hms-tenant-service
- hms-vitals-service

### Other Services
- homechef-api

## Adding NATS to a New Service

When creating a new service that uses NATS:

1. **Add NATS environment variable** in `values.yaml`:
   ```yaml
   env:
     NATS_URL: "nats://nats.nats.svc.cluster.local:4222"
   ```

2. **Add required pod annotations** in `values.yaml`:
   ```yaml
   podAnnotations:
     # Istio sidecar configuration - wait for proxy before starting app
     proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
     # Exclude NATS port from Istio sidecar to fix JetStream timeout issues
     traffic.sidecar.istio.io/excludeOutboundPorts: "4222"
   ```

3. **Verify after deployment**:
   ```bash
   # Check pod annotations
   kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.metadata.annotations}'

   # Check NATS connectivity in logs
   kubectl logs deployment/<service-name> -n <namespace> | grep -i nats
   ```

## Verification

After deploying a service with NATS, verify connectivity:

### Expected Log Output
```
[NATS] Connecting to nats://nats.nats.svc.cluster.local:4222
[NATS] Connected successfully to nats://nats.nats.svc.cluster.local:4222
[NATS] Created stream TENANT_EVENTS
[NATS] Starting subscriptions...
[NATS] Subscribed to tenant.> events on stream TENANT_EVENTS
[NATS] All subscriptions started
```

### Verification Commands

```bash
# Check if annotation is applied to deployment
kubectl get deployment <service-name> -n marketplace \
  -o jsonpath='{.spec.template.metadata.annotations.traffic\.sidecar\.istio\.io/excludeOutboundPorts}'
# Expected output: 4222

# Verify all services have the annotation
for svc in tenant-service tenant-router-service notification-service auth-service; do
  echo -n "$svc: "
  kubectl get deployment $svc -n marketplace \
    -o jsonpath='{.spec.template.metadata.annotations.traffic\.sidecar\.istio\.io/excludeOutboundPorts}'
  echo ""
done
```

## NATS Infrastructure

### NATS Server Location
- **Namespace**: `nats`
- **Service**: `nats.nats.svc.cluster.local:4222`
- **Monitoring**: `nats.nats.svc.cluster.local:8222`

### JetStream Streams

| Stream | Purpose | Consumers |
|--------|---------|-----------|
| TENANT_EVENTS | Tenant lifecycle events | tenant-router-service |
| NOTIFICATION_EVENTS | Notification events | notification-service, notification-hub |
| BOOKKEEPING | Bookkeeping domain events | bookkeeping-* services |

## Troubleshooting

### Issue: NATS connection timeout
**Symptoms**: `context deadline exceeded` errors
**Solution**: Verify `excludeOutboundPorts: "4222"` annotation is present

```bash
kubectl get deployment <service> -n <namespace> -o yaml | grep -A5 podAnnotations
```

### Issue: Pods not picking up annotation changes
**Solution**: Force pod recreation

```bash
kubectl rollout restart deployment/<service-name> -n <namespace>
```

### Issue: Intermittent connection drops
**Check**: NATS server health

```bash
kubectl get pods -n nats
kubectl logs -n nats deployment/nats
```

## Production Checklist

Before deploying to production:

- [ ] All NATS-using services have `excludeOutboundPorts: "4222"` annotation
- [ ] All services have `proxy.istio.io/config` with `holdApplicationUntilProxyStarts: true`
- [ ] NATS streams are pre-created or service has permissions to create them
- [ ] NATS connection is verified in staging/devtest environment
- [ ] Monitoring alerts configured for NATS connection failures
- [ ] Service logs show successful NATS connection on startup

## Related Documentation

- [Istio Traffic Management](https://istio.io/latest/docs/reference/config/annotations/)
- [NATS JetStream](https://docs.nats.io/nats-concepts/jetstream)
- [Tesseract Secrets Architecture](./SECRETS_ARCHITECTURE.md)

## Change History

| Date | Change | Author |
|------|--------|--------|
| 2026-01-07 | Initial documentation - Added NATS port exclusion to 35 services | Claude Code |
