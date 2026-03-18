# Three-Tier Secrets Architecture

This document describes the three-tier secrets management architecture for TesseractHub, using GCP Secret Manager and Cloud KMS to store secrets securely instead of Kubernetes Secrets and SealedSecrets.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                        THREE-TIER SECRETS ARCHITECTURE                               │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐         │
│  │  TIER 1: INFRA      │  │  TIER 2: CUSTOMER   │  │  TIER 3: THIRDPARTY │         │
│  │  (Infrastructure)   │  │  (Tenant Secrets)   │  │  (External APIs)    │         │
│  ├─────────────────────┤  ├─────────────────────┤  ├─────────────────────┤         │
│  │                     │  │                     │  │                     │         │
│  │  KMS Keys:          │  │  KMS Keys:          │  │  KMS Keys:          │         │
│  │  ├─ infra-secrets   │  │  ├─ customer-secrets│  │  ├─ thirdparty-     │         │
│  │  │  -encryption-key │  │  │  -encryption-key │  │  │  secrets-enc-key │         │
│  │  ├─ infra-database  │  │  ├─ customer-data   │  │  ├─ thirdparty-api  │         │
│  │  │  -encryption-key │  │  │  -encryption-key │  │  │  -encryption-key │         │
│  │  └─ infra-signing   │  │  └─ customer-signing│  │  └─ thirdparty-     │         │
│  │     -key            │  │     -key            │  │     signing-key     │         │
│  │                     │  │                     │  │                     │         │
│  │  Secrets:           │  │  Secrets:           │  │  Secrets:           │         │
│  │  ├─ db-credentials  │  │  ├─ tenant-configs  │  │  ├─ email (SendGrid)│         │
│  │  ├─ jwt-secrets     │  │  ├─ api-keys        │  │  ├─ payment (Stripe)│         │
│  │  └─ encryption-keys │  │  └─ credentials     │  │  └─ messaging       │         │
│  │                     │  │                     │  │     (FCM/Twilio)    │         │
│  │  Service Account:   │  │  Service Account:   │  │  Service Account:   │         │
│  │  infra-backend-     │  │  customer-tenant-   │  │  thirdparty-        │         │
│  │  secrets-sa         │  │  secrets-sa         │  │  integration-sa     │         │
│  │                     │  │                     │  │                     │         │
│  └──────────┬──────────┘  └──────────┬──────────┘  └──────────┬──────────┘         │
│             │                        │                        │                     │
│             ▼                        ▼                        ▼                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │                        GKE WORKLOAD IDENTITY                                 │   │
│  │  Kubernetes ServiceAccount ──► GCP Service Account ──► Secret Manager/KMS   │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │                        KUBERNETES PODS                                       │   │
│  │                                                                              │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │   │
│  │  │ backend-api │  │ tenant-     │  │ notification│  │ hms-backend-full    │ │   │
│  │  │ hms-backend │  │ onboarding  │  │ -service    │  │ (cross-tier access) │ │   │
│  │  │ auth-service│  │ tenant-api  │  │ payment-svc │  │                     │ │   │
│  │  │             │  │ admin-portal│  │ comm-service│  │                     │ │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │   │
│  │       │                 │                 │                    │             │   │
│  │       ▼                 ▼                 ▼                    ▼             │   │
│  │  TIER 1 Access    TIER 2 Access    TIER 3 Access       All Tiers Access     │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

## Tier Definitions

### Tier 1: Infrastructure (infra-)

**Purpose:** Internal platform secrets used by backend services to connect to databases, sign JWTs, and encrypt internal data.

| Resource Type | Name | Description |
|--------------|------|-------------|
| **KMS Keys** | | |
| | `infra-secrets-encryption-key` | Encrypts infrastructure secrets at rest |
| | `infra-database-encryption-key` | Encrypts database connection strings |
| | `infra-signing-key` | Signs JWTs and internal tokens |
| **Secrets** | | |
| | `devtest-infra-db-credentials` | PostgreSQL, Redis, MongoDB connection strings |
| | `devtest-infra-jwt-secrets` | JWT signing keys and token configs |
| | `devtest-infra-encryption-keys` | AES-256 and HMAC keys for data encryption |
| **Service Account** | | |
| | `infra-backend-secrets-sa` | Workload Identity SA for backend services |

**Bound Kubernetes ServiceAccounts:**
- `backend-api` (namespace: devtest)
- `hms-backend` (namespace: devtest)
- `auth-service` (namespace: devtest)

### Tier 2: Customer (customer-)

**Purpose:** Tenant/customer-provided secrets that apps consume. These are secrets that customers configure via admin portals or during onboarding.

| Resource Type | Name | Description |
|--------------|------|-------------|
| **KMS Keys** | | |
| | `customer-secrets-encryption-key` | Encrypts tenant-specific secrets |
| | `customer-data-encryption-key` | Encrypts PII and sensitive customer data |
| | `customer-signing-key` | Signs customer-specific certificates |
| **Secrets** | | |
| | `devtest-customer-tenant-configs` | Tenant-specific configurations |
| | `devtest-customer-api-keys` | Customer-provided API keys for integrations |
| | `devtest-customer-credentials` | Customer OAuth, SSO credentials |
| **Service Account** | | |
| | `customer-tenant-secrets-sa` | Workload Identity SA for tenant services |

**Bound Kubernetes ServiceAccounts:**
- `tenant-onboarding` (namespace: devtest)
- `tenant-api` (namespace: devtest)
- `admin-portal` (namespace: devtest)

### Tier 3: Third-Party (thirdparty-)

**Purpose:** External service credentials for third-party integrations. Kept isolated to limit blast radius if compromised.

| Resource Type | Name | Description |
|--------------|------|-------------|
| **KMS Keys** | | |
| | `thirdparty-secrets-encryption-key` | Encrypts third-party API secrets |
| | `thirdparty-api-encryption-key` | Encrypts API credentials |
| | `thirdparty-signing-key` | Signs webhook payloads |
| **Secrets** | | |
| | `devtest-thirdparty-email` | SendGrid API keys |
| | `devtest-thirdparty-payment` | Stripe API keys |
| | `devtest-thirdparty-messaging` | FCM, Twilio credentials |
| **Service Account** | | |
| | `thirdparty-integration-secrets-sa` | Workload Identity SA for integration services |

**Bound Kubernetes ServiceAccounts:**
- `communication-service` (namespace: devtest)
- `notification-service` (namespace: devtest)
- `payment-service` (namespace: devtest)

## Cross-Tier Access

For exceptional cases where a service needs access to multiple tiers (e.g., HMS backend processing patient data with third-party lab integrations):

| Service Account | Accessible Tiers | Justification |
|----------------|------------------|---------------|
| `hms-full-access-secrets-sa` | Infrastructure + Customer + Third-party | Healthcare compliance requires unified patient data processing with external lab integrations |

## Naming Conventions

### KMS Keys
```
{tier}-{purpose}-key
Examples:
  infra-secrets-encryption-key
  customer-data-encryption-key
  thirdparty-api-encryption-key
```

### Secrets
```
{environment}-{tier}-{type}
Examples:
  devtest-infra-db-credentials
  devtest-customer-tenant-configs
  devtest-thirdparty-email
```

### Service Accounts
```
{tier}-{purpose}-secrets-sa
Examples:
  infra-backend-secrets-sa
  customer-tenant-secrets-sa
  thirdparty-integration-secrets-sa
```

## Security Benefits

### Isolation
- Each tier has its own KMS keys and secrets
- Service accounts can only access their designated tier
- Compromise in one tier doesn't affect others

### Least Privilege
- Services only have access to secrets they need
- No project-wide secret accessor roles
- Fine-grained IAM bindings per secret

### Encryption
- All secrets encrypted with CMEK (Customer Managed Encryption Keys)
- Each tier has dedicated encryption keys
- Key rotation every 90 days

### Auditability
- All access logged in Cloud Audit Logs
- Per-tier access patterns are visible
- Easy to detect anomalous access

## How Pods Access Secrets

### 1. Workload Identity Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. Pod starts with ServiceAccount annotation:                           │
│    iam.gke.io/gcp-service-account: infra-backend-secrets-sa@project.iam │
├─────────────────────────────────────────────────────────────────────────┤
│ 2. GKE Metadata Server validates the annotation                         │
├─────────────────────────────────────────────────────────────────────────┤
│ 3. Pod receives short-lived access token from Google IAM                │
├─────────────────────────────────────────────────────────────────────────┤
│ 4. Pod uses token to access Secret Manager/KMS                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2. Kubernetes ServiceAccount Example

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-api
  namespace: devtest
  annotations:
    # Tier 1: Infrastructure access
    iam.gke.io/gcp-service-account: infra-backend-secrets-sa@tesseracthub-480811.iam.gserviceaccount.com
```

### 3. Application Code (Node.js Example)

```javascript
const { SecretManagerServiceClient } = require('@google-cloud/secret-manager');
const client = new SecretManagerServiceClient();

// Access infrastructure secret (Tier 1)
async function getDbCredentials() {
  const [version] = await client.accessSecretVersion({
    name: 'projects/tesseracthub-480811/secrets/devtest-infra-db-credentials/versions/latest'
  });
  return version.payload.data.toString('utf8');
}
```

## Migration from Kubernetes Secrets

### Before (Kubernetes Secrets + SealedSecrets)
```yaml
# Sealed secret that gets decrypted to K8s secret
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: db-credentials
spec:
  encryptedData:
    password: AgBy3i4OJSWK+PiTySYZZA...
```

### After (GCP Secret Manager)
```javascript
// Application directly accesses GCP Secret Manager
const credentials = await secretClient.accessSecretVersion({
  name: 'projects/PROJECT/secrets/devtest-infra-db-credentials/versions/latest'
});
```

### Benefits of Migration
1. **No local secret storage** - Secrets never stored in etcd
2. **Version control** - Secret Manager maintains version history
3. **Rotation support** - Built-in rotation with Cloud Functions
4. **Access logging** - Complete audit trail in Cloud Audit Logs
5. **Fine-grained access** - Per-secret IAM bindings

## Terraform Resources

All resources are created via the `vault` module in Terraform:

```hcl
# terraform/configs/devtest/terraform.tfvars

# KMS Keys (9 total - 3 per tier)
kms_keys = [
  # Tier 1: Infrastructure
  { name = "infra-secrets-encryption-key", ... },
  { name = "infra-database-encryption-key", ... },
  { name = "infra-signing-key", ... },

  # Tier 2: Customer
  { name = "customer-secrets-encryption-key", ... },
  { name = "customer-data-encryption-key", ... },
  { name = "customer-signing-key", ... },

  # Tier 3: Third-party
  { name = "thirdparty-secrets-encryption-key", ... },
  { name = "thirdparty-api-encryption-key", ... },
  { name = "thirdparty-signing-key", ... },
]

# Secrets (9 total - 3 per tier)
secrets = [
  # Tier 1: Infrastructure
  { secret_id = "devtest-infra-db-credentials", ... },
  { secret_id = "devtest-infra-jwt-secrets", ... },
  { secret_id = "devtest-infra-encryption-keys", ... },

  # Tier 2: Customer
  { secret_id = "devtest-customer-tenant-configs", ... },
  { secret_id = "devtest-customer-api-keys", ... },
  { secret_id = "devtest-customer-credentials", ... },

  # Tier 3: Third-party
  { secret_id = "devtest-thirdparty-email", ... },
  { secret_id = "devtest-thirdparty-payment", ... },
  { secret_id = "devtest-thirdparty-messaging", ... },
]

# Service Accounts with Workload Identity bindings
secret_accessor_service_accounts = [
  { name = "infra-backend-secrets-sa", ... },
  { name = "customer-tenant-secrets-sa", ... },
  { name = "thirdparty-integration-secrets-sa", ... },
  { name = "hms-full-access-secrets-sa", ... },  # Cross-tier
]
```

## Quick Reference

### List All Secrets by Tier
```bash
# Tier 1: Infrastructure
gcloud secrets list --filter="labels.tier=infrastructure"

# Tier 2: Customer
gcloud secrets list --filter="labels.tier=customer"

# Tier 3: Third-party
gcloud secrets list --filter="labels.tier=thirdparty"
```

### Add Secret Version
```bash
# Add new version to infrastructure secret
echo -n '{"host":"localhost","port":5432}' | \
  gcloud secrets versions add devtest-infra-db-credentials --data-file=-
```

### Verify Workload Identity Binding
```bash
# Check if KSA can impersonate GSA
gcloud iam service-accounts get-iam-policy \
  infra-backend-secrets-sa@tesseracthub-480811.iam.gserviceaccount.com
```

## Related Documentation

- [Kubernetes to GCP Secret Manager Integration Guide](./secrets-management.md)
- [GCP Secret Manager Documentation](https://cloud.google.com/secret-manager/docs)
- [Cloud KMS Documentation](https://cloud.google.com/kms/docs)
- [Workload Identity Documentation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
