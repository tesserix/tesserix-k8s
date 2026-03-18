# Tesserix Kubernetes Infrastructure

Helm charts and deployment configurations for Tesserix applications on AKS.

## Repository Structure

```
tesserix-k8s/
├── argocd/
│   └── devtest/                    # ArgoCD Application manifests for devtest environment
│       ├── app-of-apps.yaml        # Root application for deploying all apps
│       ├── products-service.yaml   # Backend microservices
│       ├── categories-service.yaml
│       ├── orders-service.yaml
│       ├── coupons-service.yaml
│       ├── settings-service.yaml
│       ├── auth-service.yaml
│       ├── staff-service.yaml
│       ├── vendor-service.yaml
│       ├── reviews-service.yaml
│       ├── tickets-service.yaml
│       ├── document-service.yaml
│       ├── location-service.yaml
│       ├── tenant-service.yaml
│       ├── verification-service.yaml
│       ├── products-hub.yaml       # MFE microfrontends
│       ├── categories-hub.yaml
│       ├── orders-hub.yaml
│       ├── staff-hub.yaml
│       ├── vendor-hub.yaml
│       ├── coupons-hub.yaml
│       ├── reviews-hub.yaml
│       ├── tickets-hub.yaml
│       ├── user-management.yaml
│       ├── admin.yaml              # Frontend applications
│       ├── storefront.yaml
│       └── tenant-onboarding.yaml
├── charts/
│   ├── apps/                       # Application Helm charts
│   │   ├── # Backend Microservices (Go - Port 8080)
│   │   ├── products-service/       # Product management
│   │   ├── categories-service/     # Category management
│   │   ├── orders-service/         # Order management
│   │   ├── coupons-service/        # Coupon and discount management
│   │   ├── settings-service/       # Application settings
│   │   ├── auth-service/           # Authentication and authorization
│   │   ├── staff-service/          # Staff management
│   │   ├── vendor-service/         # Vendor management
│   │   ├── reviews-service/        # Product reviews and ratings
│   │   ├── tickets-service/        # Support ticket management
│   │   ├── document-service/       # Document management and storage
│   │   ├── location-service/       # Countries, states, currencies, timezones
│   │   ├── tenant-service/         # Tenant management
│   │   ├── verification-service/   # Email/phone verification
│   │   │
│   │   ├── # MFE Microfrontends (Nginx - Port 80)
│   │   ├── products-hub/           # Products MFE
│   │   ├── categories-hub/         # Categories MFE
│   │   ├── orders-hub/             # Orders MFE
│   │   ├── staff-hub/              # Staff MFE
│   │   ├── vendor-hub/             # Vendor MFE
│   │   ├── coupons-hub/            # Coupons MFE
│   │   ├── reviews-hub/            # Reviews MFE
│   │   ├── tickets-hub/            # Tickets MFE
│   │   ├── user-management/        # User management MFE
│   │   │
│   │   ├── # Frontend Applications (Next.js - Port 80)
│   │   ├── admin/                  # Admin portal
│   │   ├── storefront/             # Customer-facing storefront
│   │   └── tenant-onboarding/      # Tenant onboarding wizard
│   │
│   ├── kargo/                      # Kargo Helm charts
│   │   └── kargo-project/          # Reusable Kargo project chart
│   │       ├── Chart.yaml
│   │       ├── values.yaml
│   │       └── templates/
│   │           ├── project.yaml    # Kargo Project resource
│   │           ├── warehouse.yaml  # Warehouse per service
│   │           ├── stage-dev.yaml  # Dev stage
│   │           ├── stage-staging.yaml
│   │           └── stage-production.yaml
│   │
│   └── thirdparty/                 # Third-party Helm charts
│       ├── postgresql/             # PostgreSQL database
│       └── kong-values.yaml        # Kong ingress values
│
├── kargo/                          # Kargo environment configurations
│   └── devtest/
│       ├── values.yaml             # DevTest environment values (15 services)
│       └── kargo-application.yaml  # ArgoCD Application for Kargo
│
├── credentials/                    # Documentation only - secrets created manually
│   └── (see GitHub App & OAuth Configuration section)
│
└── README.md
```

## Prerequisites

- Azure CLI with AKS credentials
- kubectl
- Helm 3.x
- Access to GHCR (GitHub Container Registry)

## Cluster Connection

```bash
export KUBECONFIG=~/.kube/marketplace-aks-cluster
kubectl cluster-info
```

## Deployment Steps

### 1. Create Namespaces

```bash
kubectl create namespace database
kubectl create namespace onboarding
kubectl create namespace global-svc
kubectl create namespace ingress-controller
kubectl create namespace cert-manager
```

### 2. Deploy PostgreSQL

```bash
helm install postgresql ./charts/thirdparty/postgresql \
  --namespace database \
  --set postgresql.password=<YOUR_SECURE_PASSWORD>
```

**Configuration:**
- Storage: 60Gi Standard SSD (managed-csi)
- Port: 5432
- Database: tesseract_hub
- User: postgres

### 3. Copy Secrets to App Namespaces

```bash
# Get PostgreSQL password
PASSWORD=$(kubectl get secret postgresql -n database -o jsonpath='{.data.postgresql-password}')

# Copy to onboarding namespace
kubectl create secret generic postgresql-password \
  --from-literal=postgresql-password="$(echo $PASSWORD | base64 -d)" \
  -n onboarding

# Copy to global-svc namespace
kubectl create secret generic postgresql-password \
  --from-literal=postgresql-password="$(echo $PASSWORD | base64 -d)" \
  -n global-svc
```

### 4. Create GHCR Image Pull Secrets

```bash
# Create in onboarding namespace
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=<GITHUB_USERNAME> \
  --docker-password=<GITHUB_PAT> \
  --docker-email=<EMAIL> \
  -n onboarding

# Copy to global-svc namespace
kubectl get secret ghcr-secret -n onboarding -o yaml > /tmp/ghcr-secret.yaml
sed -i 's/namespace: onboarding/namespace: global-svc/' /tmp/ghcr-secret.yaml
kubectl apply -f /tmp/ghcr-secret.yaml
```

### 5. Create Verification Service Secrets

```bash
# Create secrets for verification-service (global-svc)
kubectl create secret generic verification-secrets \
  --from-literal=email-api-key=<RESEND_API_KEY> \
  --from-literal=api-key=<VERIFICATION_API_KEY> \
  --from-literal=encryption-key=<32_CHAR_ENCRYPTION_KEY> \
  -n global-svc

# Create API key for tenant-service (onboarding)
kubectl create secret generic verification-api-key \
  --from-literal=api-key=<VERIFICATION_API_KEY> \
  -n onboarding
```

### 6. Deploy Backend Services

```bash
# Deploy tenant-service (onboarding namespace)
helm install tenant-service ./charts/apps/tenant-service \
  --namespace onboarding

# Deploy location-service (global-svc namespace)
helm install location-service ./charts/apps/location-service \
  --namespace global-svc

# Deploy verification-service (global-svc namespace)
helm install verification-service ./charts/apps/verification-service \
  --namespace global-svc
```

### 7. Deploy Tenant Onboarding App

```bash
helm install tenant-onboarding ./charts/apps/tenant-onboarding \
  --namespace onboarding
```

**Configuration:**
- Image: ghcr.io/tesserix/tesseract-hub/tenant-onboarding:latest
- Port: 3000
- Ingress: dev-onboarding.tesserix.app

### 8. Deploy Kong Ingress Controller

```bash
helm install kong kong/kong \
  --namespace ingress-controller \
  -f ./charts/thirdparty/kong-values.yaml
```

Get LoadBalancer IP:
```bash
kubectl get svc -n ingress-controller kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

### 9. Deploy Cert-Manager and Let's Encrypt

```bash
# Add Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager with resource limits (required for AKS policies)
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.13.3 \
  --set installCRDs=true \
  --set startupapicheck.enabled=false \
  --set resources.requests.cpu=10m \
  --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=128Mi \
  --set cainjector.resources.requests.cpu=10m \
  --set cainjector.resources.requests.memory=32Mi \
  --set cainjector.resources.limits.cpu=100m \
  --set cainjector.resources.limits.memory=128Mi \
  --set webhook.resources.requests.cpu=10m \
  --set webhook.resources.requests.memory=32Mi \
  --set webhook.resources.limits.cpu=100m \
  --set webhook.resources.limits.memory=128Mi

# Wait for cert-manager pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
```

Create Let's Encrypt ClusterIssuers:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@tesserix.app
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@tesserix.app
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

Verify ClusterIssuers are ready:
```bash
kubectl get clusterissuer
```

### 10. Deploy External DNS with Cloudflare

External DNS automatically manages DNS records in Cloudflare based on Ingress/Service annotations.

**Step 1: Create Cloudflare API Token**

1. Go to Cloudflare Dashboard → My Profile → API Tokens
2. Click "Create Token"
3. Use "Edit zone DNS" template with:
   - Permissions: Zone → DNS → Edit
   - Zone Resources: Include → Specific zone → tesserix.app
4. Copy the token

**Step 2: Create secrets for cert-manager**

```bash
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=<YOUR_CLOUDFLARE_API_TOKEN> \
  -n cert-manager
```

**Step 3: Install External DNS**

```bash
# Add External DNS Helm repository
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update

# Install with Cloudflare configuration (proxy enabled by default)
helm install external-dns external-dns/external-dns \
  --namespace ingress-controller \
  --set provider=cloudflare \
  --set "env[0].name=CF_API_TOKEN" \
  --set "env[0].value=<YOUR_CLOUDFLARE_API_TOKEN>" \
  --set "domainFilters[0]=tesserix.app" \
  --set policy=sync \
  --set resources.requests.cpu=10m \
  --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=128Mi \
  --set "extraArgs[0]=--cloudflare-proxied"
```

**Important Configuration Notes:**

- `--cloudflare-proxied`: Enables Cloudflare proxy (orange cloud) by default for all DNS records created by external-dns. This provides:
  - DDoS protection
  - SSL/TLS encryption at the edge
  - Caching and performance optimization
  - Hides origin server IP addresses

- To disable proxy for specific ingresses, add the annotation: `external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"`

**Step 4: Update ClusterIssuers for DNS01 challenge**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        cloudflare:
          email: your-email@example.com
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
EOF
```

### 11. Deploy Cloudflare Tunnel (Optional)

For secure ingress without exposing a public IP:

```bash
# Add Cloudflare Helm repository
helm repo add cloudflare https://cloudflare.github.io/helm-charts
helm repo update

# Install cloudflared tunnel with resource limits (required for AKS)
helm install cloudflared cloudflare/cloudflare-tunnel-remote \
  --namespace ingress-controller \
  --set cloudflare.tunnelToken=<YOUR_TUNNEL_TOKEN> \
  --set resources.requests.cpu=10m \
  --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=128Mi
```

To get a tunnel token:
1. Go to Cloudflare Zero Trust dashboard
2. Access > Tunnels > Create a tunnel
3. Copy the tunnel token

### 12. Configure DNS

With External DNS configured, DNS records are automatically created from Ingress annotations. For manual setup, point `dev-onboarding.tesserix.app` to the Kong LoadBalancer IP.

### 13. Enable TLS on Ingress

Update existing ingress to use automatic TLS certificates:

```bash
# Patch ingress with TLS configuration and cert-manager annotation
kubectl patch ingress tenant-onboarding -n onboarding --type=json -p='[
  {"op": "add", "path": "/metadata/annotations/cert-manager.io~1cluster-issuer", "value": "letsencrypt-prod"},
  {"op": "add", "path": "/spec/tls", "value": [{"hosts": ["dev-onboarding.tesserix.app"], "secretName": "dev-onboarding-tls"}]}
]'
```

Or add these fields to your Ingress manifest:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
  - hosts:
    - dev-onboarding.tesserix.app
    secretName: dev-onboarding-tls
```

Cert-manager will automatically:
- Create a Certificate resource
- Issue a Let's Encrypt certificate via DNS01 challenge
- Store it in the specified secret
- Renew it before expiration (30 days prior)

## Service URLs

### Infrastructure Services

| Service | Namespace | Internal URL | External URL |
|---------|-----------|-------------|--------------|
| PostgreSQL | database | postgresql.database.svc.cluster.local:5432 | - |

### Backend Microservices (Go - Port 8080)

| Service | Namespace | Internal URL |
|---------|-----------|-------------|
| Products Service | ecommerce | products-service.ecommerce.svc.cluster.local:8080 |
| Categories Service | ecommerce | categories-service.ecommerce.svc.cluster.local:8080 |
| Orders Service | ecommerce | orders-service.ecommerce.svc.cluster.local:8080 |
| Coupons Service | ecommerce | coupons-service.ecommerce.svc.cluster.local:8080 |
| Settings Service | ecommerce | settings-service.ecommerce.svc.cluster.local:8080 |
| Auth Service | common | auth-service.common.svc.cluster.local:8080 |
| Staff Service | common | staff-service.common.svc.cluster.local:8080 |
| Vendor Service | common | vendor-service.common.svc.cluster.local:8080 |
| Reviews Service | common | reviews-service.common.svc.cluster.local:8080 |
| Tickets Service | common | tickets-service.common.svc.cluster.local:8080 |
| Document Service | common | document-service.common.svc.cluster.local:8080 |
| Location Service | global-svc | location-service.global-svc.svc.cluster.local:8080 |
| Tenant Service | onboarding | tenant-service.onboarding.svc.cluster.local:8080 |
| Verification Service | onboarding | verification-service.onboarding.svc.cluster.local:8080 |

### MFE Microfrontends (Nginx - Port 80)

| MFE | Namespace | Internal URL |
|-----|-----------|-------------|
| Products Hub | mfe | products-hub.mfe.svc.cluster.local:80 |
| Categories Hub | mfe | categories-hub.mfe.svc.cluster.local:80 |
| Orders Hub | mfe | orders-hub.mfe.svc.cluster.local:80 |
| Staff Hub | mfe | staff-hub.mfe.svc.cluster.local:80 |
| Vendor Hub | mfe | vendor-hub.mfe.svc.cluster.local:80 |
| Coupons Hub | mfe | coupons-hub.mfe.svc.cluster.local:80 |
| Reviews Hub | mfe | reviews-hub.mfe.svc.cluster.local:80 |
| Tickets Hub | mfe | tickets-hub.mfe.svc.cluster.local:80 |
| User Management | mfe | user-management.mfe.svc.cluster.local:80 |

### Frontend Applications (Next.js - Port 80)

| App | Namespace | Internal URL | External URL |
|-----|-----------|-------------|--------------|
| Admin Portal | frontend | admin.frontend.svc.cluster.local:80 | https://dev-admin.tesserix.app |
| Storefront | frontend | storefront.frontend.svc.cluster.local:80 | https://dev-store.tesserix.app |
| Tenant Onboarding | onboarding | tenant-onboarding.onboarding.svc.cluster.local:80 | https://dev-onboarding.tesserix.app |

## Upgrading Releases

```bash
# Upgrade PostgreSQL
helm upgrade postgresql ./charts/thirdparty/postgresql --namespace database

# Upgrade Tenant Onboarding
helm upgrade tenant-onboarding ./charts/apps/tenant-onboarding --namespace onboarding

# Upgrade Backend Services
helm upgrade tenant-service ./charts/apps/tenant-service --namespace onboarding
helm upgrade location-service ./charts/apps/location-service --namespace global-svc
helm upgrade verification-service ./charts/apps/verification-service --namespace global-svc
```

## Useful Commands

```bash
# Check pod status
kubectl get pods -n onboarding
kubectl get pods -n global-svc
kubectl get pods -n database

# View logs
kubectl logs -f deployment/tenant-onboarding -n onboarding
kubectl logs -f deployment/tenant-service -n onboarding
kubectl logs -f deployment/location-service -n global-svc
kubectl logs -f deployment/verification-service -n global-svc

# Get PostgreSQL password
kubectl get secret postgresql -n database -o jsonpath='{.data.postgresql-password}' | base64 -d

# Port-forward PostgreSQL for local access
kubectl port-forward svc/postgresql 5432:5432 -n database

# Check ingress
kubectl get ingress -n onboarding

# Check services
kubectl get svc -n onboarding
kubectl get svc -n global-svc

# Check cert-manager
kubectl get pods -n cert-manager
kubectl get clusterissuer
kubectl get certificates -A

# Check External DNS
kubectl get pods -n ingress-controller -l app.kubernetes.io/name=external-dns
kubectl logs -f -n ingress-controller -l app.kubernetes.io/name=external-dns
```

## Environment Variables

### Tenant Onboarding (Next.js)

| Variable | Value |
|----------|-------|
| TENANT_SERVICE_URL | http://tenant-service.onboarding.svc.cluster.local:8080 |
| LOCATION_SERVICE_URL | http://location-service.global-svc.svc.cluster.local:8080 |

### Backend Services (Go)

| Variable | Value |
|----------|-------|
| PORT | 8080 |
| GIN_MODE | release |
| DB_HOST | postgresql.database.svc.cluster.local |
| DB_PORT | 5432 |
| DB_NAME | tesseract_hub |
| DB_USER | postgres |
| DB_PASSWORD | (from secret) |

### Verification Service Additional

| Variable | Value |
|----------|-------|
| EMAIL_PROVIDER | resend |
| EMAIL_FROM | onboarding@tesserix.app |
| EMAIL_API_KEY | (from secret) |
| API_KEY | (from secret) |
| ENCRYPTION_KEY | (from secret) |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│         Tenant Onboarding UI (Next.js)              │
│              dev-onboarding.tesserix.app            │
└────────────┬────────────────────────────────────────┘
             │ (BFF Pattern - Next.js API Routes)
             │
    ┌────────┼────────┬────────────────────┐
    │        │        │                    │
    ▼        ▼        ▼                    ▼
┌────────┐ ┌──────────────┐ ┌────────────────────┐
│Tenant  │ │Verification  │ │Location Service    │
│Service │ │Service       │ │(Countries, States) │
│:8080   │ │:8080         │ │:8080               │
│onboard │ │global-svc    │ │global-svc          │
└────┬───┘ └──────┬───────┘ └────────┬───────────┘
     │            │                   │
     └────────────┴───────────────────┘
                  │
                  ▼
         ┌──────────────────┐
         │   PostgreSQL     │
         │   database ns    │
         │     :5432        │
         └──────────────────┘
```

## ArgoCD GitOps Deployment

ArgoCD Application manifests are provided for GitOps-based deployments. The `argocd/devtest/` directory contains all application definitions for the devtest environment.

### Namespace Organization

| Namespace | Services |
|-----------|----------|
| `ecommerce` | products-service, categories-service, orders-service, coupons-service, settings-service |
| `common` | auth-service, staff-service, vendor-service, reviews-service, tickets-service, document-service |
| `global-svc` | location-service |
| `onboarding` | tenant-service, verification-service, tenant-onboarding |
| `mfe` | products-hub, categories-hub, orders-hub, staff-hub, vendor-hub, coupons-hub, reviews-hub, tickets-hub, user-management |
| `frontend` | admin, storefront |

### Deploy All Applications (App of Apps Pattern)

The easiest way to deploy all applications is using the App of Apps pattern:

```bash
# Apply the root application - this will deploy all other applications
kubectl apply -f argocd/devtest/app-of-apps.yaml
```

This creates a parent ArgoCD Application that automatically discovers and deploys all other applications in the `argocd/devtest/` directory.

### Deploy Individual Applications

To deploy individual applications:

```bash
# Deploy a single microservice
kubectl apply -f argocd/devtest/products-service.yaml

# Deploy a single MFE
kubectl apply -f argocd/devtest/products-hub.yaml

# Deploy a frontend app
kubectl apply -f argocd/devtest/admin.yaml
```

### ArgoCD Application Features

Each ArgoCD Application is configured with:

- **Automated Sync**: Applications automatically sync when changes are detected
- **Self-Heal**: Automatically corrects drift from the desired state
- **Prune**: Removes resources that are no longer defined
- **Namespace Creation**: Automatically creates target namespaces
- **Retry Policy**: Automatic retries with exponential backoff

### Sync Policies

All applications use the following sync policy:

```yaml
syncPolicy:
  automated:
    prune: true      # Remove resources not in Git
    selfHeal: true   # Correct drift automatically
  syncOptions:
    - CreateNamespace=true
    - PruneLast=true
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m
```

### Pre-requisites for ArgoCD Deployment

Before deploying applications via ArgoCD:

1. **Create Required Secrets** in each namespace:
   ```bash
   # GHCR image pull secret
   kubectl create secret docker-registry ghcr-secret \
     --docker-server=ghcr.io \
     --docker-username=<GITHUB_USERNAME> \
     --docker-password=<GITHUB_PAT> \
     --docker-email=<EMAIL> \
     -n <namespace>

   # PostgreSQL password
   kubectl create secret generic postgresql-password \
     --from-literal=postgresql-password=<PASSWORD> \
     -n <namespace>
   ```

2. **Ensure ArgoCD is installed**:
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

   **ArgoCD UI Access**: https://dev-argocd.tesserix.app

   **Login Options:**
   - **GitHub OAuth**: Click "LOG IN VIA GITHUB" (recommended)
   - **Admin Account**: Username `admin`, get password with:
     ```bash
     kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
     ```

3. **Register the Git repository** (if private):
   ```bash
   argocd repo add https://github.com/tesserix/tesserix-k8s.git \
     --username <USERNAME> \
     --password <PAT>
   ```

### Viewing Application Status

```bash
# List all applications
argocd app list

# Get detailed status of an application
argocd app get products-service

# Sync an application manually
argocd app sync products-service

# View application logs
argocd app logs products-service
```

### Adding New Environments

To add a new environment (e.g., `staging`, `production`):

1. Create a new directory: `argocd/<environment>/`
2. Copy application files from `devtest/`
3. Update the following in each file:
   - `metadata.labels.environment`
   - `spec.source.targetRevision` (use specific branch/tag)
   - `spec.destination.namespace` (if different)
   - Any environment-specific Helm parameters

## Kargo GitOps Promotion

Kargo provides automated promotion of container images across environments with approval workflows.

### Kargo Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Kargo Project                           │
│                    (tesseract-hub-devtest)                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │  Warehouse  │───▶│  Dev Stage  │───▶│  Staging Stage      │  │
│  │  (per svc)  │    │  (auto)     │    │  (manual approval)  │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│        │                                         │              │
│        │           Watches for:                  │              │
│        │           - New container images        │              │
│        │           - Git changes (Helm charts)   ▼              │
│        │                               ┌─────────────────────┐  │
│        └──────────────────────────────▶│  Production Stage   │  │
│                                        │  (manual approval)  │  │
│                                        └─────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Deploy Kargo Project

```bash
# Deploy using ArgoCD Application
kubectl apply -f kargo/devtest/kargo-application.yaml

# Or deploy directly with Helm
helm install tesseract-hub-devtest charts/kargo/kargo-project \
  -f kargo/devtest/values.yaml \
  -n tesseract-hub-devtest --create-namespace
```

### Kargo Resources

| Resource | Description |
|----------|-------------|
| **Project** | Namespace-scoped container for Warehouses and Stages |
| **Warehouse** | Watches container registries and Git repos for new artifacts |
| **Stage** | Represents an environment (dev, staging, prod) |
| **Freight** | Immutable artifact reference (image tag + git commit) |
| **Promotion** | Request to move Freight to a Stage |

### View Kargo Status

```bash
# View project
kubectl get projects.kargo.akuity.io -n tesseract-hub-devtest

# View warehouses
kubectl get warehouses.kargo.akuity.io -n tesseract-hub-devtest

# View stages
kubectl get stages.kargo.akuity.io -n tesseract-hub-devtest

# View freight (available artifacts)
kubectl get freight.kargo.akuity.io -n tesseract-hub-devtest

# View promotions
kubectl get promotions.kargo.akuity.io -n tesseract-hub-devtest
```

### Kargo UI Access

Access Kargo UI at: https://dev-kargo.tesserix.app

**Login Options:**
- **GitHub OAuth**: Click "Login with GitHub" (recommended)
- **Admin Account**: Username `admin`, Password `admin123`

### Adding New Services to Kargo

To add a new service to Kargo promotion:

1. Edit `kargo/devtest/values.yaml`
2. Add the service to the `services` list:

```yaml
services:
  - name: new-service
    type: backend        # backend, mfe, or frontend
    namespace: ecommerce
    imageRepo: new-service
    chartPath: charts/apps/new-service
```

3. Commit and push - ArgoCD will sync the changes

### Adding New Environments to Kargo

1. Create a new values file: `kargo/<environment>/values.yaml`
2. Update the project name and stages configuration:

```yaml
project:
  name: tesseract-hub-staging

stages:
  dev:
    enabled: false
  staging:
    enabled: true
    autoPromotion: true
  production:
    enabled: true
    autoPromotion: false  # Manual approval for prod
```

3. Create an ArgoCD Application for the new environment

## CI/CD Pipeline for Helm Charts

GitHub Actions workflows are configured for automated Helm chart linting, testing, and releasing to GHCR.

### Available Workflows

| Workflow | Trigger | Description |
|----------|---------|-------------|
| `helm-lint.yaml` | Push/PR to main/develop | Lints charts, validates templates, runs security scans |
| `helm-release.yaml` | Release publish, manual | Packages and pushes changed charts to GHCR |
| `helm-release-all.yaml` | Manual dispatch | Releases ALL charts at once (with dry-run option) |
| `pr-validation.yaml` | Pull requests | Validates Helm charts and ArgoCD manifests |
| `scheduled-release.yaml` | Daily at 2 AM UTC | Nightly releases with date-suffixed versions |

### Workflow Features

**Linting & Validation:**
- chart-testing (ct) for Helm chart linting
- kubeconform for Kubernetes manifest validation
- Trivy for vulnerability scanning
- Checkov for security best practices

**Release Process:**
- Automatic detection of changed charts
- Semantic versioning from Chart.yaml
- OCI registry push to GHCR
- Matrix strategy for parallel releases

### Pulling Charts from GHCR

```bash
# Authenticate to GHCR
helm registry login ghcr.io -u <GITHUB_USERNAME> -p <GITHUB_PAT>

# Pull a specific chart
helm pull oci://ghcr.io/<OWNER>/charts/<CHART_NAME> --version <VERSION>

# Install directly from GHCR
helm install <RELEASE_NAME> oci://ghcr.io/<OWNER>/charts/<CHART_NAME> --version <VERSION>
```

### Manual Release Trigger

To release all charts manually:

1. Go to **Actions** → **Helm Release All Charts**
2. Click **Run workflow**
3. Options:
   - `version_suffix`: Add suffix like `rc1`, `beta1` (optional)
   - `dry_run`: Package without pushing (for testing)

### Nightly Releases

Scheduled releases run daily at 2 AM UTC:
- Only runs if there were commits in the last 24 hours
- Version format: `<base-version>-nightly.<YYYYMMDD>`
- Can be force-triggered via workflow dispatch

### Configuration Files

| File | Purpose |
|------|---------|
| `.github/ct.yaml` | chart-testing configuration |
| `.github/lintconf.yaml` | YAML lint rules |

## Monitoring & Observability

### Grafana

Grafana provides dashboards for monitoring Kubernetes clusters, applications, and infrastructure.

**Access:**
- **URL**: https://dev-grafana.tesserix.app
- **GitHub Login**: Click "Sign in with GitHub" (recommended)
- **Admin Login**: Username `admin`, get password with:
  ```bash
  kubectl get secret -n monitoring grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo
  ```

**Pre-configured Dashboards:**

| Folder | Dashboard | Description |
|--------|-----------|-------------|
| General | Node Exporter Full | Comprehensive node metrics (CPU, memory, disk, network) |
| General | Kubernetes Cluster Monitoring | Cluster-wide resource utilization |
| General | Kubernetes Views - Global | Cluster overview and health |
| General | Kubernetes Views - Pods | Per-pod resource metrics |
| General | Kubernetes Views - Namespaces | Namespace-level resource usage |
| General | Kubernetes Views - Nodes | Per-node metrics and status |
| General | CoreDNS | DNS query metrics and performance |
| Kubernetes | Kubernetes API Server | API server performance and latency |
| Kubernetes | Kubernetes Compute Resources - Cluster | Cluster compute resource allocation |
| Kubernetes | Kubernetes Compute Resources - Namespace | Namespace compute resources |
| Kubernetes | Kubernetes Compute Resources - Pod | Pod-level compute metrics |
| Kubernetes | Kubernetes Networking - Cluster | Network traffic and bandwidth |
| Kubernetes | NGINX Ingress Controller | Ingress request rates and latencies |
| Istio | Istio Mesh Dashboard | Service mesh traffic overview |
| Istio | Istio Service Dashboard | Per-service mesh metrics |
| Istio | Istio Workload Dashboard | Workload-level mesh metrics |
| Istio | Istio Control Plane | Istiod and control plane health |

**Data Sources:**
- **Prometheus**: `http://prometheus-server.monitoring.svc.cluster.local:80`
- **Elasticsearch**: `http://elasticsearch-master.logging.svc.cluster.local:9200` (for log queries)

**GitHub OAuth Configuration:**

Grafana is configured with GitHub OAuth login. To set up for a new environment:

1. Create a GitHub OAuth App at `https://github.com/settings/developers`
   - **Homepage URL**: `https://dev-grafana.tesserix.app`
   - **Authorization callback URL**: `https://dev-grafana.tesserix.app/login/github`

2. Create the OAuth secret:
   ```bash
   kubectl create secret generic grafana-github-oauth -n monitoring \
     --from-literal=GF_AUTH_GITHUB_CLIENT_ID=<CLIENT_ID> \
     --from-literal=GF_AUTH_GITHUB_CLIENT_SECRET=<CLIENT_SECRET>
   ```

3. The Grafana Helm values include:
   ```yaml
   auth.github:
     enabled: true
     allow_sign_up: true
     scopes: user:email,read:org
     auth_url: https://github.com/login/oauth/authorize
     token_url: https://github.com/login/oauth/access_token
     api_url: https://api.github.com/user
   ```

**Restricting Access (Optional):**

To restrict login to specific GitHub organizations, add to `grafana.ini`:
```yaml
auth.github:
  allowed_organizations: tesserix
```

### Prometheus

Prometheus collects and stores metrics from Kubernetes and applications.

**Access:**
- **Internal URL**: `http://prometheus-server.monitoring.svc.cluster.local:80`
- Prometheus is not exposed externally by default; use `kubectl port-forward` for access

**Metrics Sources:**
- Node Exporter (node-level metrics)
- kube-state-metrics (Kubernetes object state)
- cAdvisor (container metrics)
- Application metrics (custom `/metrics` endpoints)

### ELK Stack (Logging)

The ELK stack provides centralized logging for all cluster workloads.

**Components:**

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Elasticsearch | logging | Log storage and indexing (120GB SSD) |
| Kibana | logging | Log visualization and querying |
| Fluent Bit | logging | Log collection (DaemonSet) |

**Access:**

- **Kibana**: https://dev-kibana.tesserix.app
- **Elasticsearch**: Internal only at `http://elasticsearch-master.logging.svc.cluster.local:9200`

**Log Indices:**
- `fluentbit-kube-*` - Kubernetes container logs
- `fluentbit-host-*` - Host system logs

**Configuration Notes:**
- Elasticsearch security is disabled for dev environment
- Kibana 7.17.3 (compatible with security-disabled ES)
- Fluent Bit collects logs from all pods in all namespaces

## Future Automation (TODO)

- [x] ArgoCD GitOps setup
- [x] Cert-manager for automatic TLS certificates
- [x] CI/CD pipeline for Helm chart deployments
- [x] Monitoring with Prometheus/Grafana
- [x] Logging with ELK Stack
- [ ] External Secrets Operator for secret management
- [ ] Automated secret rotation
- [ ] Alerting rules and notifications

## AKS-Specific Requirements

### Azure Policy Resource Limits

AKS clusters with Azure Policy enabled require all containers to have resource limits defined. If you see errors like:

```
admission webhook "validation.gatekeeper.sh" denied the request: container has no resource limits
```

You must set resource limits for all deployments. This is why cert-manager requires explicit resource limit configuration.

### Cert-Manager Installation Notes

The standard cert-manager installation will fail on AKS due to Azure Policy. Key fixes:

1. **Disable startup API check** - `startupapicheck.enabled=false` (avoids timeout issues)
2. **Set resource limits** for all components (controller, cainjector, webhook)
3. **Wait for webhook** - The webhook pod must be ready before creating ClusterIssuers

### Kong Ingress Controller

Kong is configured with `ingressClass: nginx` to work with cert-manager's HTTP01 solver. Ensure your values file includes:

```yaml
ingressController:
  ingressClass: nginx
proxy:
  type: LoadBalancer
```

## Troubleshooting

### Image Pull Errors
Ensure `ghcr-secret` exists in the namespace and has valid credentials.

### Database Connection Issues
Verify the PostgreSQL pod is running and the password secret is correctly copied to the namespace.

### Ingress Not Working
Check Kong pods are running and the IngressClass matches (`nginx`).

### ArgoCD Ingress Not Working (No ADDRESS)

If the ArgoCD ingress shows no ADDRESS and Kong logs show `KongConfigurationTranslationFailed: Failed to fetch the secret`, the issue is likely:

1. **Missing TLS certificate** - ArgoCD's default helm values use SSL passthrough without cert-manager
2. **Wrong backend protocol** - SSL passthrough doesn't work well with Kong

**Fix:**

```bash
# 1. Patch the ingress to use cert-manager and HTTP backend
kubectl patch ingress argocd-server -n argocd --type=json -p='[
  {"op": "add", "path": "/metadata/annotations/cert-manager.io~1cluster-issuer", "value": "letsencrypt-prod"},
  {"op": "remove", "path": "/metadata/annotations/nginx.ingress.kubernetes.io~1ssl-passthrough"},
  {"op": "remove", "path": "/metadata/annotations/nginx.ingress.kubernetes.io~1backend-protocol"},
  {"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/port/number", "value": 80}
]'

# 2. Configure ArgoCD server for insecure mode (TLS terminates at ingress)
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'

# 3. Restart the server to apply config
kubectl rollout restart deployment argocd-server -n argocd

# 4. Wait for certificate to be issued
kubectl get certificate -n argocd -w
```

**For fresh ArgoCD installations, use these helm values:**

```yaml
configs:
  params:
    server.insecure: true

server:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
    hosts:
      - dev-argo.tesserix.app
    tls:
      - hosts:
          - dev-argo.tesserix.app
        secretName: argocd-server-tls
```

### Kargo Ingress Not Working (No ADDRESS)

Kargo API runs with HTTPS internally, so Kong needs to connect via HTTPS to the backend. The fix requires:
1. Adding cert-manager annotation for the ingress TLS certificate
2. Removing ssl-passthrough annotation
3. Adding Kong-specific `konghq.com/protocol=https` annotation to the services

**Fix:**

```bash
# 1. Patch the ingress to use cert-manager
kubectl patch ingress kargo-api -n kargo --type=json -p='[
  {"op": "add", "path": "/metadata/annotations/cert-manager.io~1cluster-issuer", "value": "letsencrypt-prod"},
  {"op": "remove", "path": "/metadata/annotations/nginx.ingress.kubernetes.io~1ssl-passthrough"}
]'

# 2. Annotate Kargo services for HTTPS backend (Kong-specific)
kubectl annotate svc kargo-api -n kargo konghq.com/protocol=https --overwrite
kubectl annotate svc kargo-external-webhooks-server -n kargo konghq.com/protocol=https --overwrite

# 3. Wait for certificate to be issued
kubectl get certificate -n kargo -w
```

**For fresh Kargo installations, use these helm values:**

```yaml
api:
  host: dev-kargo.tesserix.app
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
      # Note: Do NOT use nginx.ingress.kubernetes.io/backend-protocol with Kong
    tls:
      enabled: true
      selfSignedCert: false
  # Keep internal TLS enabled - Kong will connect via HTTPS
  tls:
    enabled: true
    selfSignedCert: true
```

**Important:** With Kong ingress controller, you must annotate the services (not ingress) with `konghq.com/protocol=https` for HTTPS backends:

```bash
kubectl annotate svc kargo-api -n kargo konghq.com/protocol=https
kubectl annotate svc kargo-external-webhooks-server -n kargo konghq.com/protocol=https
```

### Service Communication Issues
Verify services can reach each other using full DNS names (e.g., `service.namespace.svc.cluster.local`).

### Certificate Issues

Check cert-manager logs and certificate status:

```bash
kubectl logs -f deployment/cert-manager -n cert-manager
kubectl describe certificate <cert-name> -n <namespace>
kubectl describe clusterissuer letsencrypt-prod
```

### Azure Policy Blocking Deployments

If pods fail to create with "gatekeeper" or "validation webhook" errors:

```bash
# Check events for the deployment
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Common fix: Add resource limits to your deployment
resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    cpu: 100m
    memory: 128Mi
```

### Cert-Manager Webhook Not Ready

If ClusterIssuer creation fails with "no endpoints available for service cert-manager-webhook":

```bash
# Wait for all cert-manager pods
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s

# Then create ClusterIssuers
```

### Resetting Kargo Admin Password

Kargo stores the admin password as a bcrypt hash. To reset it:

```bash
# 1. Generate a new bcrypt hash for your desired password
# Option A: Using htpasswd
htpasswd -nbBC 10 "" "your-new-password" | tr -d ':\n' | sed 's/^://'

# Option B: Using Python
python3 -c "import bcrypt; print(bcrypt.hashpw(b'your-new-password', bcrypt.gensalt(rounds=10)).decode())"

# 2. Base64 encode the hash and update the secret
NEW_HASH='$2a$10$YOUR_GENERATED_HASH_HERE'
kubectl patch secret kargo-api -n kargo --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/data/ADMIN_ACCOUNT_PASSWORD_HASH\", \"value\": \"$(echo -n "$NEW_HASH" | base64)\"}]"

# 3. Restart Kargo API to apply the new password
kubectl rollout restart deployment kargo-api -n kargo
```

### Getting ArgoCD Admin Password

```bash
# Get the initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d && echo
```

## GitHub App & OAuth Configuration

### GitHub App for Repository Access

A GitHub App is used for ArgoCD and Kargo to access the Git repository. This is more secure than PATs and supports fine-grained permissions.

**Creating a GitHub App:**

1. Go to: `https://github.com/organizations/tesserix/settings/apps/new`
2. Configure:
   - **Name**: `tesseract-argocd-kargo`
   - **Homepage URL**: `https://dev-argocd.tesserix.app`
   - **Webhook**: Uncheck "Active"
3. Repository Permissions:
   - **Contents**: Read-only
   - **Metadata**: Read-only
   - **Packages**: Read-only
4. Generate a **Private Key** (downloads a `.pem` file)
5. Install the App on `tesserix` organization for `tesserix-k8s` repo

**Current Configuration:**
- **App ID**: `2373185`
- **Installation ID**: `96994524`

### Configuring ArgoCD Repository Credentials (GitHub App)

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: repo-tesserix-k8s
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/tesserix/tesserix-k8s.git
  githubAppID: "2373185"
  githubAppInstallationID: "96994524"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    <YOUR_PRIVATE_KEY_CONTENT>
    -----END RSA PRIVATE KEY-----
EOF
```

### Configuring Kargo Repository Credentials (GitHub App)

Kargo credentials must be created in both the `kargo` namespace and the project namespace:

```bash
# Create in kargo namespace
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: github-repo-creds
  namespace: kargo
  labels:
    kargo.akuity.io/cred-type: git
stringData:
  repoURL: https://github.com/tesserix/tesserix-k8s.git
  repoURLIsRegex: "false"
  githubAppID: "2373185"
  githubAppInstallationID: "96994524"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    <YOUR_PRIVATE_KEY_CONTENT>
    -----END RSA PRIVATE KEY-----
EOF

# Create in project namespace (repeat for each Kargo project)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: github-repo-creds
  namespace: tesseract-hub-devtest
  labels:
    kargo.akuity.io/cred-type: git
stringData:
  repoURL: https://github.com/tesserix/tesserix-k8s.git
  repoURLIsRegex: "false"
  githubAppID: "2373185"
  githubAppInstallationID: "96994524"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    <YOUR_PRIVATE_KEY_CONTENT>
    -----END RSA PRIVATE KEY-----
EOF
```

### GHCR (Container Registry) Credentials

GitHub Apps don't work with GHCR - you need a Classic PAT with `read:packages` scope.

**Creating a Classic PAT:**
1. Go to: `https://github.com/settings/tokens/new`
2. Select scopes: `read:packages`
3. Generate and copy the token

**Configuring Kargo GHCR Credentials:**

```bash
# Create in kargo namespace
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-image-creds
  namespace: kargo
  labels:
    kargo.akuity.io/cred-type: image
stringData:
  repoURL: ghcr.io
  repoURLIsRegex: "false"
  username: tesserix
  password: <YOUR_GITHUB_PAT>
EOF

# Create in project namespace
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-image-creds
  namespace: tesseract-hub-devtest
  labels:
    kargo.akuity.io/cred-type: image
stringData:
  repoURL: ghcr.io
  repoURLIsRegex: "false"
  username: tesserix
  password: <YOUR_GITHUB_PAT>
EOF
```

**Creating ImagePullSecrets for Kubernetes Deployments:**

```bash
# Create in each application namespace
for ns in ecommerce global-svc onboarding; do
  kubectl create secret docker-registry ghcr-pull-secret \
    --namespace=$ns \
    --docker-server=ghcr.io \
    --docker-username=tesserix \
    --docker-password=<YOUR_GITHUB_PAT> \
    --docker-email=devops@tesserix.app
done
```

### GitHub OAuth for Login

Both ArgoCD and Kargo support GitHub OAuth for user authentication.

**Creating OAuth Apps:**

1. **ArgoCD OAuth App**: `https://github.com/organizations/tesserix/settings/applications/new`
   - **Name**: `Tesseract ArgoCD`
   - **Homepage URL**: `https://dev-argocd.tesserix.app`
   - **Callback URL**: `https://dev-argocd.tesserix.app/api/dex/callback`

2. **Kargo OAuth App**: Create another OAuth App
   - **Name**: `Tesseract Kargo`
   - **Homepage URL**: `https://dev-kargo.tesserix.app`
   - **Callback URL**: `https://dev-kargo.tesserix.app/api/v1alpha1/oidc/callback`

**Configuring ArgoCD GitHub OAuth:**

```bash
# Configure Dex with GitHub connector
kubectl patch configmap argocd-cm -n argocd --type merge -p '
{
  "data": {
    "url": "https://dev-argocd.tesserix.app",
    "dex.config": "connectors:\n  - type: github\n    id: github\n    name: GitHub\n    config:\n      clientID: <ARGOCD_OAUTH_CLIENT_ID>\n      clientSecret: $dex.github.clientSecret\n      orgs:\n        - name: tesserix\n"
  }
}'

# Add client secret
kubectl patch secret argocd-secret -n argocd --type merge -p '{
  "stringData": {
    "dex.github.clientSecret": "<ARGOCD_OAUTH_CLIENT_SECRET>"
  }
}'

# Configure RBAC - org members get admin access
kubectl patch configmap argocd-rbac-cm -n argocd --type merge -p '
{
  "data": {
    "policy.default": "role:readonly",
    "policy.csv": "g, tesserix:*, role:admin\n"
  }
}'

# Restart to apply
kubectl rollout restart deployment argocd-server argocd-dex-server -n argocd
```

**Configuring Kargo GitHub OAuth:**

```bash
# Configure OIDC
kubectl patch configmap kargo-api -n kargo --type merge -p '{
  "data": {
    "OIDC_ENABLED": "true",
    "OIDC_ISSUER_URL": "https://github.com",
    "OIDC_CLIENT_ID": "<KARGO_OAUTH_CLIENT_ID>",
    "OIDC_GLOBAL_SERVICE_ACCOUNTS_NAMESPACES": "kargo",
    "OIDC_ADMINS_GROUP": "tesserix"
  }
}'

# Add client secret
kubectl patch secret kargo-api -n kargo --type merge -p '{
  "stringData": {
    "OIDC_CLIENT_SECRET": "<KARGO_OAUTH_CLIENT_SECRET>"
  }
}'

# Restart to apply
kubectl rollout restart deployment kargo-api -n kargo
```

### Current OAuth Configuration

| Platform | OAuth App Client ID | Login URL |
|----------|---------------------|-----------|
| ArgoCD | `Ov23liEwDs63TF4f6aLN` | https://dev-argo.tesserix.app |
| Kargo | `Ov23lixGvLHnQz0DlNSa` | https://dev-kargo.tesserix.app |

### RBAC Configuration

Both ArgoCD and Kargo are configured to grant admin access to all members of the **tesserix** GitHub organization.

**ArgoCD RBAC:**

The ArgoCD RBAC is configured via ConfigMap. All tesserix org members get admin access:

```bash
# View current RBAC policy
kubectl get configmap argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.csv}'

# Configure RBAC for tesserix org (already applied)
kubectl patch configmap argocd-rbac-cm -n argocd --type merge -p '
{
  "data": {
    "policy.default": "role:readonly",
    "policy.csv": "g, tesserix:*, role:admin\n",
    "policy.matchMode": "glob",
    "scopes": "[groups]"
  }
}'

# Restart ArgoCD server to apply RBAC changes
kubectl rollout restart deployment argocd-server -n argocd
```

**Kargo RBAC:**

Kargo uses Kubernetes RBAC with a ClusterRoleBinding. All tesserix org members get admin access via the `github:tesserix` group.

**IMPORTANT:** Kargo Dex requires `loadAllGroups: true` in the GitHub connector config to populate organization groups. Without this setting, users will see "projects.kargo.akuity.io is forbidden: list is not permitted" because the groups claim will be empty.

```bash
# View current Kargo RBAC binding
kubectl get clusterrolebinding kargo-github-tesserix-admin -o yaml

# Create ClusterRoleBinding for tesserix org (already applied)
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kargo-github-tesserix-admin
  labels:
    app.kubernetes.io/name: kargo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kargo-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: "github:tesserix"
EOF

# Restart Kargo API to apply RBAC changes
kubectl rollout restart deployment kargo-api -n kargo
```

**Kargo Dex GitHub Connector Configuration:**

The Kargo Helm values must include `loadAllGroups: true` in the GitHub connector:

```yaml
api:
  oidc:
    enabled: true
    dex:
      enabled: true
      connectors:
      - id: github
        name: GitHub
        type: github
        config:
          clientID: <OAUTH_CLIENT_ID>
          clientSecret: $GITHUB_CLIENT_SECRET
          redirectURI: https://dev-kargo.tesserix.app/dex/callback
          orgs:
          - name: tesserix
          loadAllGroups: true  # CRITICAL: Required for org group membership
      env:
      - name: GITHUB_CLIENT_SECRET
        value: "<OAUTH_CLIENT_SECRET>"
```

If you need to fix this on an existing deployment:

```bash
# 1. Upgrade Kargo with the corrected Helm values
helm upgrade kargo oci://ghcr.io/akuity/kargo-charts/kargo -n kargo \
  -f your-values.yaml

# 2. Or manually patch the Dex server secret and restart
# (See the Helm values above for the correct configuration)

# 3. Verify groups are populated by checking Dex logs after login
kubectl logs -l app.kubernetes.io/component=dex-server -n kargo | grep "login successful"
# Should show: groups=[tesserix] instead of groups=[]
```

**RBAC Summary:**

| Platform | Group | Role | Permission Level |
|----------|-------|------|------------------|
| ArgoCD | `tesserix:*` | `role:admin` | Full admin access to all applications, clusters, repos |
| Kargo | `github:tesserix` | `kargo-admin` | Full admin access to all projects, warehouses, stages |

### Credentials Summary

| Secret | Namespace | Type | Purpose |
|--------|-----------|------|---------|
| `repo-tesserix-k8s` | argocd | GitHub App | Git repo access for ArgoCD |
| `github-repo-creds` | kargo | GitHub App | Git repo access for Kargo |
| `github-repo-creds` | tesseract-hub-devtest | GitHub App | Git repo (project-level) |
| `ghcr-image-creds` | kargo | PAT | GHCR image registry |
| `ghcr-image-creds` | tesseract-hub-devtest | PAT | GHCR images (project-level) |
| `ghcr-pull-secret` | ecommerce, global-svc, onboarding | docker-registry | ImagePullSecret for pods |

---

**Last Updated:** November 2025
