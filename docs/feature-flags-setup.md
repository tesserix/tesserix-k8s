# Feature Flags Setup Guide

This document provides comprehensive instructions for setting up and configuring the GrowthBook feature flags system for Tesserix Hub.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Components](#components)
- [Automated Feature Seeding](#automated-feature-seeding)
- [Production Setup](#production-setup)
- [Feature Flags Reference](#feature-flags-reference)
- [Configuration Options](#configuration-options)
- [Troubleshooting](#troubleshooting)

---

## Overview

Tesserix Hub uses [GrowthBook](https://www.growthbook.io/) as the feature flags management system. The setup includes:

- **GrowthBook** - Self-hosted feature flags and A/B testing platform
- **Feature Flags Service** - Go microservice that proxies GrowthBook SDK API
- **Automated Seeding** - Kubernetes Job that creates all 34 predefined feature flags on deployment

### Key Benefits

- Centralized feature flag management via GrowthBook UI
- Multi-tenant support with attribute-based targeting
- Automatic seeding ensures consistent feature flags across environments
- SDK integration for React, mobile, and backend services

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Tesserix Hub                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐    ┌─────────────────────┐    ┌────────────────┐ │
│  │  Admin App   │───▶│ Feature Flags Svc   │───▶│   GrowthBook   │ │
│  │  (Next.js)   │    │     (Go/Gin)        │    │   (Node.js)    │ │
│  └──────────────┘    └─────────────────────┘    └───────┬────────┘ │
│                                                          │          │
│  ┌──────────────┐                               ┌───────▼────────┐ │
│  │ Storefront   │───────────────────────────────│    MongoDB     │ │
│  │  (Next.js)   │    SDK Direct Connection      │                │ │
│  └──────────────┘                               └────────────────┘ │
│                                                                      │
│  ┌──────────────┐                                                   │
│  │ Mobile App   │───────────────────────────────▶ SDK Endpoint     │
│  │  (React N.)  │                                                   │
│  └──────────────┘                                                   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Port Configuration

GrowthBook uses a dual-port architecture:
- **Port 3000** - Next.js Frontend (Dashboard UI)
- **Port 3100** - Express Backend (API & SDK endpoints)

---

## Components

### 1. GrowthBook Deployment

**Location:** `charts/thirdparty/growthbook/`

The GrowthBook Helm chart includes:
- Main GrowthBook deployment (growthbook/growthbook image)
- MongoDB for data persistence
- Persistent volumes for uploads
- ExternalSecrets for JWT and encryption keys

### 2. Feature Flags Service

**Location:** `charts/apps/feature-flags-service/`

A Go microservice that:
- Proxies GrowthBook SDK API for internal services
- Adds caching layer (configurable TTL)
- Provides tenant-aware feature evaluation
- Exposes Prometheus metrics

### 3. Feature Seeding Job

**Location:** `charts/thirdparty/growthbook/templates/feature-seed-*.yaml`

Kubernetes Job that automatically creates all 34 feature flags on GrowthBook install/upgrade.

---

## Automated Feature Seeding

### How It Works

1. **Helm/ArgoCD deploys GrowthBook** with the seeding configuration enabled
2. **PostSync hook triggers** the feature seeding Job after deployment
3. **Seeding Job executes** the following steps:
   - Waits for GrowthBook health check
   - Registers/logs in admin user
   - Gets organization ID from user info
   - Creates SDK connection if not exists
   - Creates all 34 feature flags (skips existing ones)

### Seeding Script Flow

```
┌─────────────────────┐
│  Wait for Health    │
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│  Register/Login     │
│   Admin User        │
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│  Get Organization   │
│   from /user API    │
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│  Create SDK         │
│  Connection         │
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│  Create 34 Feature  │
│  Flags (skip exist) │
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│     Complete!       │
└─────────────────────┘
```

---

## Production Setup

### Prerequisites

1. Kubernetes cluster with:
   - External Secrets Operator installed
   - ArgoCD for GitOps deployments
   - Istio service mesh (for VirtualService routing)

2. Access to GCP Secret Manager in `tesseracthub-480811`

### Step 1: Store the admin password

```bash
ADMIN_PASSWORD=$(openssl rand -base64 24)
echo -n "$ADMIN_PASSWORD" | gcloud secrets versions add prod-growthbook-admin-password \
  --project=tesseracthub-480811 --data-file=-
```

### Step 2: Store the JWT secret and encryption key

```bash
echo -n "$(openssl rand -hex 32)" | gcloud secrets versions add prod-growthbook-jwt-secret \
  --project=tesseracthub-480811 --data-file=-
echo -n "$(openssl rand -hex 32)" | gcloud secrets versions add prod-growthbook-encryption-key \
  --project=tesseracthub-480811 --data-file=-
```

An ExternalSecret in the `growthbook` namespace projects both into
`growthbook-secrets`.

### Step 3: Create ArgoCD Application

Create `argocd/production/infrastructure/growthbook.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: growthbook
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    app.kubernetes.io/part-of: tesseract-hub
    app.kubernetes.io/component: feature-flags
spec:
  project: default
  source:
    repoURL: https://github.com/tesserix/tesserix-k8s.git
    path: charts/thirdparty/growthbook
    targetRevision: HEAD
    helm:
      releaseName: growthbook
      values: |
        replicaCount: 2  # HA for production

        image:
          repository: growthbook/growthbook
          tag: "latest"
          pullPolicy: Always

        service:
          type: ClusterIP
          appPort: 3000
          apiPort: 3100

        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 2000m
            memory: 2Gi

        config:
          nodeEnv: "production"
          appOrigin: "https://growthbook.yourdomain.com"
          apiHost: "https://growthbook.yourdomain.com:443"
          uploadMethod: "local"  # or "s3" for production
          disableTelemetry: true
          enableOpenFeature: true

        secrets:
          jwtSecretName: "growthbook-secrets"
          jwtSecretKey: "jwt-secret"
          encryptionKeySecretName: "growthbook-secrets"
          encryptionKeyKey: "encryption-key"

        mongodb:
          enabled: true
          image:
            repository: mongo
            tag: "7.0"
          auth:
            enabled: true  # Enable auth for production
            # Credentials come from the growthbook ExternalSecret
          persistence:
            enabled: true
            size: 50Gi  # Larger for production
            storageClassName: premium-rwo

        persistence:
          enabled: true
          size: 20Gi
          storageClassName: premium-rwo

        extraEnv:
          - name: ALLOW_SELF_ORG_CREATION
            value: "false"  # Disable after initial setup
          - name: IS_MULTI_ORG
            value: "false"
          - name: IS_CLOUD
            value: "false"
          - name: AUTH_TYPE
            value: "local"

        # Feature Seeding Configuration
        featureSeeding:
          enabled: true
          adminEmail: "admin@yourdomain.com"
          adminName: "Production Admin"
          createAdminSecret: false
          adminPasswordSecret:
            name: "growthbook-admin"
            key: "password"
          image:
            repository: curlimages/curl
            tag: "8.5.0"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi

  destination:
    server: https://kubernetes.default.svc
    namespace: growthbook
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### Step 4: Create the ExternalSecret

Create `external-secrets/prod/growthbook/externalsecret.yaml` mapping
`prod-growthbook-jwt-secret` and `prod-growthbook-encryption-key` onto the
`growthbook-secrets` Secret keys `jwt-secret` and `encryption-key`.

### Step 5: Update Feature Flags Service

Update `charts/apps/feature-flags-service/values.yaml` for production:

```yaml
env:
  GROWTHBOOK_API_HOST: "growthbook.growthbook.svc.cluster.local"
  GROWTHBOOK_API_PORT: "3100"
  CACHE_TTL_SECONDS: "300"  # 5 min cache for production
  ENABLE_CACHE: "true"
```

### Step 6: Update Admin App SDK Key

After deployment, get the SDK key from GrowthBook and update the Admin app:

```bash
# Get SDK key from GrowthBook (login first)
# Or check the seeding job logs for the SDK key

# Store it in GCP Secret Manager
echo -n "sdk-XXXXXX" | gcloud secrets versions add prod-growthbook-sdk-client-key \
  --project=tesseracthub-480811 --data-file=-
```

Update `charts/apps/admin/values.yaml`:

```yaml
growthbook:
  enabled: true
  secretName: "growthbook-sdk-secret"
  secretKey: "sdk-client-key"
```

### Step 7: Configure Istio VirtualService

Add GrowthBook routing to your Istio VirtualService:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: growthbook
  namespace: growthbook
spec:
  hosts:
    - growthbook.yourdomain.com
  gateways:
    - istio-system/main-gateway
  http:
    # Backend API routes (port 3100)
    - match:
        - uri:
            regex: ^/(auth|organization|user|feature|sdk-connections|api|healthcheck)(/.*)?$
      route:
        - destination:
            host: growthbook
            port:
              number: 3100
    # Frontend routes (port 3000)
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: growthbook
            port:
              number: 3000
```

---

## Feature Flags Reference

### Search Features

| Feature Key | Description | Default |
|-------------|-------------|---------|
| `global_search_enabled` | Enable global search functionality across the platform | `true` |
| `search_autocomplete` | Enable search autocomplete suggestions | `true` |
| `search_typo_tolerance` | Enable typo tolerance in search | `true` |
| `advanced_search_filters` | Enable advanced search filters | `false` |

### E-Commerce Features

| Feature Key | Description | Default |
|-------------|-------------|---------|
| `multi_currency` | Enable multi-currency support | `true` |
| `guest_checkout` | Allow guest checkout without account | `true` |
| `wishlist_enabled` | Enable wishlist functionality | `true` |
| `product_reviews` | Enable product reviews and ratings | `true` |
| `product_compare` | Enable product comparison feature | `false` |
| `bulk_ordering` | Enable bulk ordering functionality | `false` |

### Payment Features

| Feature Key | Description | Default |
|-------------|-------------|---------|
| `apple_pay` | Enable Apple Pay payment method | `false` |
| `google_pay` | Enable Google Pay payment method | `false` |
| `buy_now_pay_later` | Enable Buy Now Pay Later options | `false` |
| `subscription_payments` | Enable subscription-based payments | `false` |

### UI/UX Features

| Feature Key | Description | Default |
|-------------|-------------|---------|
| `dark_mode` | Enable dark mode theme option | `false` |
| `new_checkout_flow` | Enable new checkout flow design | `false` |
| `product_quick_view` | Enable product quick view modal | `true` |
| `infinite_scroll` | Enable infinite scroll on product lists | `false` |
| `sticky_header` | Enable sticky navigation header | `true` |

### Admin Features

| Feature Key | Description | Default |
|-------------|-------------|---------|
| `analytics_dashboard_v2` | Enable new analytics dashboard version | `false` |
| `bulk_product_edit` | Enable bulk product editing | `true` |
| `ai_product_descriptions` | Enable AI-generated product descriptions | `false` |
| `inventory_alerts` | Enable inventory alert notifications | `true` |

### Mobile Features

| Feature Key | Description | Default |
|-------------|-------------|---------|
| `biometric_auth` | Enable biometric authentication | `false` |
| `push_notifications` | Enable push notifications | `true` |
| `offline_mode` | Enable offline mode support | `false` |
| `ar_product_preview` | Enable AR product preview | `false` |

### Performance Features

| Feature Key | Description | Default |
|-------------|-------------|---------|
| `image_lazy_loading` | Enable lazy loading for images | `true` |
| `service_worker` | Enable service worker for caching | `false` |
| `prefetch_enabled` | Enable link prefetching | `true` |

### Multi-Tenant Features

| Feature Key | Description | Default |
|-------------|-------------|---------|
| `tenant_custom_domain` | Enable custom domain per tenant | `true` |
| `tenant_custom_theme` | Enable custom theme per tenant | `true` |
| `tenant_analytics` | Enable tenant-specific analytics | `true` |
| `white_label_enabled` | Enable white-label branding | `false` |

---

## Configuration Options

### featureSeeding Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `featureSeeding.enabled` | Enable automatic feature seeding | `true` |
| `featureSeeding.adminEmail` | Admin email for GrowthBook login | `admin@tesserix.app` |
| `featureSeeding.adminName` | Admin display name | `Admin` |
| `featureSeeding.createAdminSecret` | Create secret from plain text (dev only) | `false` |
| `featureSeeding.adminPassword` | Plain text password (dev only) | `""` |
| `featureSeeding.adminPasswordSecret.name` | Secret name for admin password | `growthbook-admin` |
| `featureSeeding.adminPasswordSecret.key` | Secret key for admin password | `password` |
| `featureSeeding.backoffLimit` | Job retry limit | `3` |
| `featureSeeding.ttlSecondsAfterFinished` | Job cleanup time | `600` |
| `featureSeeding.image.repository` | Seeding job image | `curlimages/curl` |
| `featureSeeding.image.tag` | Seeding job image tag | `8.5.0` |

---

## Troubleshooting

### Common Issues

#### 1. "Unexpected token '<'" JSON Error on Home Page

**Symptoms:**
- GrowthBook Home page shows error: `Unexpected token '<', "<!DOCTYPE "... is not valid JSON`
- Features page works, but Home page displays error toast
- Browser console shows JSON parsing error

**Root Cause:**
GrowthBook's frontend makes API calls to endpoints like `/experiments` using `fetch()`. By default, `fetch()` sends `Accept: */*` header, not `Accept: application/json`. If the VirtualService routes based on `Accept: application/json`, these requests incorrectly go to the frontend (port 3000) instead of the backend (port 3100), returning HTML instead of JSON.

**Solution:**
Update the VirtualService to route based on `x-organization` header instead of `Accept` header:

```yaml
# Route API calls with x-organization header to backend
- match:
    - headers:
        x-organization:
          regex: ".*"
      uri:
        regex: ^/(features|projects|experiments|environments|segments|dimensions|sdk-connections|saved-groups|settings|integrations|datasources|metrics|ideas|presentations|reports|archetypes|attributes|fact-tables|namespaces|teams|tags)(/.*)?$
  route:
    - destination:
        host: growthbook.growthbook.svc.cluster.local
        port:
          number: 3100
```

GrowthBook's frontend includes `x-organization` header in all API calls, making it a reliable discriminator for routing API calls vs page navigation.

**Verification:**
```bash
# Without x-organization → HTML (page navigation)
curl -s -o /dev/null -w "%{content_type}\n" "https://dev-growthbook.tesserix.app/experiments"
# Output: text/html

# With x-organization → JSON (API call)
curl -s -o /dev/null -w "%{content_type}\n" "https://dev-growthbook.tesserix.app/experiments" \
  -H "x-organization: org_xxx"
# Output: application/json
```

#### 2. Next.js `/_next/data/*.json` Returns HTML

**Symptoms:**
- Client-side navigation errors
- JSON parsing errors during page transitions

**Root Cause:**
GrowthBook uses Next.js static export mode (`nextExport: true`), which doesn't generate `/_next/data/*.json` files. When the frontend prefetches data for navigation, these routes fall through to the catch-all and return HTML.

**Solution:**
Add a VirtualService rule to return valid SSG JSON for `/_next/data/*.json` requests:

```yaml
- match:
    - uri:
        regex: ^/_next/data/.*\.json$
  directResponse:
    status: 200
    body:
      string: '{"pageProps":{},"__N_SSG":true}'
```

Also add an EnvoyFilter to set the correct Content-Type and cache-busting headers:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: growthbook-json-content-type
  namespace: istio-ingress
spec:
  workloadSelector:
    labels:
      app: istio-ingressgateway
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
              subFilter:
                name: envoy.filters.http.router
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.lua
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
            inlineCode: |
              function envoy_on_request(request_handle)
                local path = request_handle:headers():get(":path")
                if path and string.match(path, "^/_next/data/.*%.json$") then
                  request_handle:streamInfo():dynamicMetadata():set("lua", "is_next_data", "true")
                end
              end
              function envoy_on_response(response_handle)
                local is_next_data = response_handle:streamInfo():dynamicMetadata():get("lua")
                if is_next_data and is_next_data["is_next_data"] == "true" then
                  response_handle:headers():replace("content-type", "application/json")
                  response_handle:headers():replace("cache-control", "no-cache, no-store, must-revalidate")
                end
              end
```

#### 3. Seeding Job Fails with "Failed to get organization ID"

**Cause:** Admin user not associated with an organization.

**Solution:** The seeding script now uses `/user` endpoint to get org ID. If still failing:
```bash
# Check user info
kubectl exec -n growthbook deploy/growthbook -- \
  curl -s http://localhost:3100/user \
  -H "Authorization: Bearer <TOKEN>"
```

#### 2. Features Not Created

**Cause:** Features already exist with same IDs.

**Solution:** The script skips existing features. Check GrowthBook UI or:
```bash
# Check features via API
kubectl exec -n growthbook deploy/growthbook -- \
  curl -s http://localhost:3100/feature \
  -H "Authorization: Bearer <TOKEN>" \
  -H "x-organization: <ORG_ID>"
```

#### 3. SDK Key Mismatch

**Cause:** New SDK connection created on each deployment.

**Solution:** The script checks for existing connections. Get current key:
```bash
# Check SDK connections
kubectl exec -n growthbook deploy/growthbook -- \
  curl -s http://localhost:3100/sdk-connections \
  -H "Authorization: Bearer <TOKEN>" \
  -H "x-organization: <ORG_ID>"
```

#### 4. GrowthBook UI 404 Errors

**Cause:** Istio VirtualService routing issues.

**Solution:** Ensure all API endpoints route to port 3100:
- `/auth/*`, `/organization`, `/user`, `/feature/*`
- `/sdk-connections`, `/api/*`, `/healthcheck`

#### 5. Admin App Can't Fetch Features

**Cause:** Feature Flags Service can't reach GrowthBook.

**Solution:**
```bash
# Test connectivity
kubectl exec -n devtest deploy/feature-flags-service -c istio-proxy -- \
  curl -s "http://growthbook.growthbook.svc.cluster.local:3100/healthcheck"

# Check service logs
kubectl logs -n devtest deploy/feature-flags-service
```

### Useful Commands

```bash
# View seeding job logs
kubectl logs -n growthbook -l app.kubernetes.io/component=feature-seeding

# Restart seeding job manually
kubectl delete job -n growthbook -l app.kubernetes.io/component=feature-seeding
kubectl annotate application growthbook -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Check GrowthBook health
kubectl exec -n growthbook deploy/growthbook -- curl -s http://localhost:3100/healthcheck

# Get all features count
kubectl exec -n growthbook deploy/growthbook -- \
  curl -s "http://localhost:3100/api/features/<SDK_KEY>" | \
  grep -o '"[a-z_]*":{"defaultValue"' | wc -l
```

---

## Adding New Feature Flags

To add new feature flags to the automated seeding:

1. Edit `charts/thirdparty/growthbook/templates/feature-seed-configmap.yaml`
2. Add the new feature to the `features.json` data:

```json
{
  "id": "new_feature_key",
  "description": "Description of the feature",
  "valueType": "boolean",
  "defaultValue": "false",
  "tags": ["category"]
}
```

3. Update the seed.sh script if needed
4. Commit and push changes
5. ArgoCD will sync and the PostSync hook will create the new feature

---

## Security Considerations

1. **Never commit plain text passwords** - Always use GCP Secret Manager
2. **Rotate secrets periodically** - Update JWT and encryption keys
3. **Limit admin access** - Use RBAC for GrowthBook access
4. **Enable MongoDB auth** - Required for production
5. **Use HTTPS** - Configure TLS for external access
6. **Audit feature changes** - GrowthBook tracks all changes

---

## Support

For issues or questions:
- Check GrowthBook docs: https://docs.growthbook.io/
- Review Tesserix K8s repo issues
- Contact platform team

---

*Last Updated: January 2026*
