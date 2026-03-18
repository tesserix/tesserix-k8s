# Network Policies & Authentication Migration

## Overview
This document covers two major infrastructure changes:
1. Cross-namespace network policies for database and Redis access
2. Complete migration from legacy auth-service to Keycloak

---

# Part 1: Network Policies - Cross-Namespace Access

## Issue Summary
Services in the marketplace namespace need access to resources in other namespaces:
1. **PostgreSQL (postgresql-global)**: For shared services like tenant_db, auth_db, verification_db
2. **Redis (redis-marketplace)**: For caching from global namespace services
3. **Keycloak (identity-customer)**: For authentication and user management

## Configuration Changes

### 1. Cross-Product Database Access (values.yaml)
Added `crossProductDatabaseAccess` configuration to allow marketplace services to access postgresql-global:

```yaml
crossProductDatabaseAccess:
  marketplace:
    - postgresql-global  # Shared services: tenant_db, auth_db, verification_db
```

### 2. Cross-Product Redis Access (values.yaml)
Added `crossProductRedisAccess` configuration to allow global namespace services to access redis-marketplace:

```yaml
crossProductRedisAccess:
  global:
    - redis-marketplace  # Shared caching for auth, notification, etc.
```

### 3. Network Policy Template Updates (network-policies.yaml)

#### Database Ingress Policy
Added cross-product database access rules to allow specified app namespaces to access other product's databases.

#### Redis Ingress Policy
Added cross-product Redis access rules similar to database access.

#### Egress Policies
Added egress rules for both cross-product database and Redis access.

## Verification

### Network Policies Applied

**postgresql-global ingress (strict-global-db-access)**:
- global namespace: port 5432
- postgresql-global (internal): port 5432
- growthbook: port 5432
- identity-customer: port 5432
- identity-internal: port 5432
- **marketplace: port 5432** (NEW)
- monitoring: port 9187

**redis-marketplace ingress (strict-marketplace-redis-access)**:
- marketplace namespace: port 6379
- redis-marketplace (internal): ports 6379, 26379
- **global namespace: port 6379** (NEW)
- monitoring: port 9121

### Connectivity Tests

| Source | Destination | Port | Status |
|--------|-------------|------|--------|
| marketplace | postgresql-global | 5432 | SUCCESS |
| marketplace | redis-marketplace | 6379 | SUCCESS |
| marketplace | identity-customer (Keycloak) | 8080 | SUCCESS |
| global | redis-marketplace | 6379 | SUCCESS |

---

# Part 2: Authentication Migration - auth-service to Keycloak

## Summary
Complete removal of the legacy `auth-service` and migration to Keycloak for all authentication and user management.

## What Was Removed

### Deleted Files
- `charts/apps/auth-service/` - Entire Helm chart directory
  - Chart.yaml, Chart.lock
  - templates/deployment.yaml
  - templates/service.yaml
  - templates/serviceaccount.yaml
  - templates/scaledobject.yaml
  - templates/pdb.yaml
  - templates/vpa.yaml
  - values.yaml, values-prod.yaml

### Removed References
- `argocd/devtest/apps/global/auth-service.yaml` - ArgoCD Application
- `argocd/devtest/apps/global/kustomization.yaml` - Removed auth-service.yaml from resources
- `argocd/devtest/apps/marketplace/admin.yaml` - Removed AUTH_SERVICE_URL parameter
- `charts/apps/admin/values.yaml` - Removed AUTH_SERVICE_URL
- `charts/apps/tenant-service/values.yaml` - Removed AUTH_SERVICE_URL references

## Keycloak Configuration

### Identity Providers
Two Keycloak instances are used:

| Instance | URL | Realm | Purpose |
|----------|-----|-------|---------|
| Customer IDP | devtest-customer-idp.tesserix.app | tesserix-customer | Customer-facing auth (onboarding, dashboard) |
| Internal IDP | devtest-internal-idp.tesserix.app | tesserix-internal | Backend service-to-service auth |

### Clients Configured

**tesserix-customer realm:**
- `marketplace-dashboard` - Public client for admin/storefront login
- `marketplace-onboarding` - Public client for onboarding flow
- `marketplace-onboarding-admin` - Confidential client for user management (service account)

### Admin Client Secret
Stored in GCP Secret Manager:
- Secret Name: `devtest-keycloak-customer-admin-client-secret`
- Used by: tenant-service for user registration/management

### Google Identity Provider
Configured in tesserix-customer realm:
- Client ID: `849928263410-ahbf0teqe8gv6nfht22qck228b0rdnd8.apps.googleusercontent.com`
- Enabled: true
- Trust Email: true

## Services Updated

### tenant-service
Changed from hybrid to Keycloak-only:
```yaml
AUTH_VALIDATOR_TYPE: "keycloak"
KEYCLOAK_BASE_URL: "https://devtest-customer-idp.tesserix.app"
KEYCLOAK_REALM: "tesserix-customer"
KEYCLOAK_ADMIN_CLIENT_ID: "marketplace-onboarding-admin"
KEYCLOAK_PUBLIC_CLIENT_ID: "marketplace-dashboard"
KEYCLOAK_DEFAULT_ROLE: "store_owner"
```

### All Backend Services (20 services)
Updated `AUTH_VALIDATOR_TYPE` from "hybrid" to "keycloak":

| Service | Keycloak Issuer URL |
|---------|---------------------|
| analytics-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| approval-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| audit-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| categories-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| coupons-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| customers-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| gift-cards-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| inventory-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| location-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| marketing-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| orders-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| payment-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| products-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| reviews-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| settings-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| shipping-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| staff-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| tax-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| tickets-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |
| vendor-service | devtest-internal-idp.tesserix.app/realms/tesserix-internal |

## JWT Token Flow

### Authentication Flow
1. User authenticates via Keycloak (customer IDP)
2. Keycloak issues RS256 signed JWT token
3. Token contains claims: `sub`, `tenant_id`, `tenant_slug`, `role`
4. Frontend includes token in `Authorization: Bearer <token>` header
5. Backend services validate token against Keycloak JWKS endpoint

### Header Forwarding (Istio)
Configured in `istio-config/values.yaml`:
```yaml
cors:
  allowHeaders:
    - authorization
    - x-tenant-id
    - x-tenant-slug
    - x-user-id
    - x-vendor-id
    - x-storefront-id
```

## Production Readiness Checklist

- [x] All services use Keycloak RS256 JWT validation
- [x] Legacy HS256 JWT support removed (AUTH_VALIDATOR_TYPE: "keycloak")
- [x] Admin client secret stored in GCP Secret Manager
- [x] Google Identity Provider configured
- [x] Network policies allow Keycloak connectivity
- [x] CORS headers configured for JWT forwarding
- [x] auth-service completely removed from cluster
- [x] Multi-tenant user support implemented

---

# Part 3: Multi-Tenant User Support

## Overview
The platform supports multi-tenant architecture where a single user can own and manage multiple tenants (stores). This is handled by storing multiple `tenant_id` values in the user's Keycloak attributes.

## Implementation Details

### User Registration Flow
When a user completes onboarding for a new tenant:

1. **Check for existing user**: The system first checks if the user already exists in Keycloak by email
2. **Existing user**: If found, adds the new `tenant_id` to their existing attributes (no duplicate IDs)
3. **New user**: If not found, creates a new Keycloak user with the initial `tenant_id`

### Code Changes (tenant-service)

**`registerUserInKeycloak` function** (`internal/services/onboarding_service.go`):
```go
// First check if user already exists (supports multi-tenant - same user can have multiple tenants)
existingUser, err := s.keycloakClient.GetUserByEmail(ctx, email)
if existingUser != nil && existingUser.ID != "" {
    return s.addTenantToExistingUser(ctx, existingUser, tenantID)
}
// Otherwise create new user...
```

**`addTenantToExistingUser` function**:
```go
// Get existing tenant_ids from attributes
existingTenantIDs := user.Attributes["tenant_id"]
// Add new tenant_id to the list (if not duplicate)
updatedTenantIDs := append(existingTenantIDs, tenantID)
// Update user attributes in Keycloak
s.keycloakClient.UpdateUserAttributes(ctx, user.ID, map[string][]string{"tenant_id": updatedTenantIDs})
```

### Keycloak User Attributes
Users have a `tenant_id` attribute that stores an array of tenant IDs:
```json
{
  "attributes": {
    "tenant_id": [
      "uuid-of-first-tenant",
      "uuid-of-second-tenant"
    ]
  }
}
```

### Benefits
- Same email/user can onboard multiple stores
- User ID consistency across all tenants
- Single sign-on across all owned stores
- JWT token includes all tenant associations

## Commits

1. `refactor(tenant-service): migrate from auth-service to Keycloak`
2. `refactor: remove auth-service completely - migrate to Keycloak`
3. `feat(auth): migrate all services to Keycloak-only JWT validation`
4. `docs(issues): add network policies cross-namespace access documentation`
5. `feat(network-policies): allow marketplace to access postgresql-global`
6. `feat(network-policies): add cross-product Redis access for global namespace`
7. `feat(tenant-service): add multi-tenant user support in Keycloak`

## Troubleshooting

### Common Issues

**"authentication service unavailable"**
- Check if tenant-service has KEYCLOAK_ADMIN_CLIENT_SECRET loaded
- Verify GCP Secret Manager access
- Check logs: `kubectl logs -n marketplace -l app.kubernetes.io/name=tenant-service | grep -i keycloak`

**Multi-tenant user issues**
- User's `tenant_id` attribute in Keycloak should be an array containing all tenant IDs
- Check user attributes: `curl -s "http://keycloak:8080/admin/realms/tesserix-customer/users/{user-id}"`
- If tenant_id is missing, user may need to be manually updated in Keycloak admin console

**Google login 404**
- Verify Google IDP redirect URIs in Google Cloud Console
- Check Keycloak Google IDP configuration
- Ensure realm is correctly set (tesserix-customer)

### Useful Commands

```bash
# Check Keycloak admin client initialization
kubectl logs -n marketplace -l app.kubernetes.io/name=tenant-service | grep -i keycloak

# Test Keycloak admin API access
kubectl exec -n identity-customer <keycloak-pod> -c istio-proxy -- \
  curl -s "http://localhost:8080/admin/realms/tesserix-customer/users?max=5"

# Get specific user by email
kubectl exec -n identity-customer <keycloak-pod> -c istio-proxy -- \
  curl -s "http://localhost:8080/admin/realms/tesserix-customer/users?email=user@example.com&exact=true"

# Verify network policy
kubectl get networkpolicy -n postgresql-global -o yaml
```
