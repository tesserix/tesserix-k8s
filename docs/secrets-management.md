# Kubernetes to GCP Secret Manager & KMS Integration Guide

This guide provides comprehensive instructions for connecting Kubernetes pods running on GKE to GCP Secret Manager and Cloud KMS using Workload Identity.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [How Workload Identity Works](#how-workload-identity-works)
4. [Terraform Resources Created](#terraform-resources-created)
5. [Step-by-Step Setup](#step-by-step-setup)
6. [Application Integration](#application-integration)
7. [Helm Chart Integration](#helm-chart-integration)
8. [ArgoCD Integration](#argocd-integration)
9. [Using KMS for Encryption](#using-kms-for-encryption)
10. [Troubleshooting](#troubleshooting)
11. [Security Best Practices](#security-best-practices)

---

## Overview

This infrastructure uses **GCP Workload Identity** to provide secure, keyless authentication from GKE pods to GCP services. Instead of managing service account keys (which are security risks), pods automatically receive short-lived tokens that grant access to Secret Manager and KMS.

### Key Benefits

| Feature | Benefit |
|---------|---------|
| **No Service Account Keys** | Eliminates key rotation burden and leak risks |
| **Short-lived Tokens** | Tokens auto-refresh, limiting exposure window |
| **Fine-grained Access** | Each service only accesses its required secrets |
| **CMEK Encryption** | Secrets encrypted with customer-managed keys |
| **Audit Logging** | All access logged in Cloud Audit Logs |

---

## Prerequisites

Before connecting your pods to Secret Manager and KMS, ensure:

1. **GKE Cluster** with Workload Identity enabled
2. **Terraform Applied** - Run `terraform apply` with the vault module
3. **kubectl** configured to access your cluster
4. **Namespace** exists (e.g., `devtest`)

### Verify Workload Identity is Enabled

```bash
# Check GKE cluster configuration
gcloud container clusters describe tesseract-devtest-gke \
  --region=australia-southeast1 \
  --format="value(workloadIdentityConfig.workloadPool)"

# Expected output: tesseracthub-480811.svc.id.goog
```

---

## How Workload Identity Works

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              WORKLOAD IDENTITY FLOW                                  │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│   ┌──────────────────┐         ┌──────────────────┐         ┌──────────────────┐   │
│   │   Kubernetes     │         │   GKE Metadata   │         │   Google IAM     │   │
│   │   Pod            │         │   Server         │         │   Service        │   │
│   └────────┬─────────┘         └────────┬─────────┘         └────────┬─────────┘   │
│            │                            │                            │              │
│            │ 1. Request credentials     │                            │              │
│            │    (via SDK/metadata)      │                            │              │
│            │ ─────────────────────────► │                            │              │
│            │                            │                            │              │
│            │                            │ 2. Validate KSA annotation │              │
│            │                            │    and WI binding          │              │
│            │                            │ ─────────────────────────► │              │
│            │                            │                            │              │
│            │                            │ 3. Return short-lived      │              │
│            │                            │ ◄───────────────────────── │              │
│            │                            │    access token            │              │
│            │                            │                            │              │
│            │ 4. Return token            │                            │              │
│            │ ◄───────────────────────── │                            │              │
│            │                            │                            │              │
│   ┌────────▼─────────┐                                                              │
│   │   Pod uses       │         ┌──────────────────┐                                 │
│   │   token to       │────────►│  Secret Manager  │                                 │
│   │   access GCP     │         │  / KMS API       │                                 │
│   └──────────────────┘         └──────────────────┘                                 │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Identity Chain

```
Kubernetes ServiceAccount (KSA)
        │
        │ iam.gke.io/gcp-service-account annotation
        ▼
GCP Service Account (GSA)
        │
        │ IAM Roles
        ▼
┌───────┴───────────────────────────────────────────┐
│                                                    │
▼                                                    ▼
Secret Manager                                      KMS
(secretAccessor)                         (cryptoKeyEncrypterDecrypter)
```

---

## Terraform Resources Created

The vault module creates the following resources:

### KMS Resources

| Resource | Name | Purpose |
|----------|------|---------|
| Key Ring | `tesseract-devtest-keyring` | Container for crypto keys |
| Crypto Key | `secrets-encryption-key` | Encrypt secrets (CMEK) |
| Crypto Key | `database-encryption-key` | Database field encryption |
| Crypto Key | `app-encryption-key` | Application-level encryption |

### Secret Manager Resources

| Secret ID | Purpose | Accessible By |
|-----------|---------|---------------|
| `devtest-db-credentials` | Database connection strings | backend-api, tenant-onboarding, hms-backend |
| `devtest-jwt-secrets` | JWT signing keys | backend-api, hms-backend |
| `devtest-api-keys` | Third-party API keys | communication-service |
| `devtest-third-party-credentials` | SendGrid, FCM credentials | tenant-onboarding, communication-service |
| `devtest-encryption-keys` | App encryption keys | backend-api, hms-backend |

### Service Accounts

| GCP Service Account | K8s ServiceAccount | Namespace | Secrets Access |
|---------------------|-------------------|-----------|----------------|
| `backend-secrets-sa` | `backend-api` | devtest | db-credentials, jwt-secrets, encryption-keys |
| `tenant-onboarding-secrets-sa` | `tenant-onboarding` | devtest | db-credentials, third-party-credentials |
| `communication-secrets-sa` | `communication-service` | devtest | api-keys, third-party-credentials |
| `hms-secrets-sa` | `hms-backend` | devtest | db-credentials, jwt-secrets, encryption-keys |

---

## Step-by-Step Setup

### Step 1: Apply Terraform

```bash
cd terraform

# Initialize Terraform
terraform init -backend-config=configs/devtest/backend.tfvars

# Plan and review changes
terraform plan -var-file=configs/devtest/terraform.tfvars

# Apply changes
terraform apply -var-file=configs/devtest/terraform.tfvars
```

### Step 2: Add Secret Values

Terraform creates empty secrets. Populate them with actual values:

```bash
# Database credentials (JSON format recommended)
cat <<EOF | gcloud secrets versions add devtest-db-credentials --data-file=-
{
  "host": "10.0.0.5",
  "port": 5432,
  "database": "tesseract_devtest",
  "username": "app_user",
  "password": "your-secure-password",
  "sslmode": "require"
}
EOF

# JWT secrets
cat <<EOF | gcloud secrets versions add devtest-jwt-secrets --data-file=-
{
  "access_token_secret": "$(openssl rand -base64 64)",
  "refresh_token_secret": "$(openssl rand -base64 64)",
  "access_token_expiry": "15m",
  "refresh_token_expiry": "7d"
}
EOF

# API keys
cat <<EOF | gcloud secrets versions add devtest-api-keys --data-file=-
{
  "stripe_secret_key": "sk_test_xxx",
  "stripe_webhook_secret": "whsec_xxx"
}
EOF

# Third-party credentials
cat <<EOF | gcloud secrets versions add devtest-third-party-credentials --data-file=-
{
  "sendgrid_api_key": "SG.xxx",
  "fcm_server_key": "xxx",
  "twilio_account_sid": "ACxxx",
  "twilio_auth_token": "xxx"
}
EOF

# Encryption keys
cat <<EOF | gcloud secrets versions add devtest-encryption-keys --data-file=-
{
  "aes_256_key": "$(openssl rand -base64 32)",
  "hmac_key": "$(openssl rand -base64 32)"
}
EOF
```

### Step 3: Create Kubernetes ServiceAccount

Create the Kubernetes ServiceAccount with the Workload Identity annotation:

```yaml
# k8s/service-accounts/backend-api-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-api
  namespace: devtest
  annotations:
    # This annotation binds the K8s SA to the GCP SA
    iam.gke.io/gcp-service-account: backend-secrets-sa@tesseracthub-480811.iam.gserviceaccount.com
  labels:
    app: backend-api
    managed-by: terraform
```

Apply:

```bash
kubectl apply -f k8s/service-accounts/backend-api-sa.yaml
```

### Step 4: Configure Your Deployment

Reference the ServiceAccount in your Deployment:

```yaml
# k8s/deployments/backend-api.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-api
  namespace: devtest
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      # Use the ServiceAccount with Workload Identity
      serviceAccountName: backend-api

      # Recommended: Don't mount default SA token
      automountServiceAccountToken: false

      containers:
        - name: api
          image: your-registry/backend-api:latest

          env:
            # Pass project ID for SDK initialization
            - name: GCP_PROJECT_ID
              value: "tesseracthub-480811"

            # Pass secret names (not values!)
            - name: DB_SECRET_NAME
              value: "devtest-db-credentials"
            - name: JWT_SECRET_NAME
              value: "devtest-jwt-secrets"

          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi

          # Health checks
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
```

### Step 5: Verify the Setup

```bash
# Check ServiceAccount annotation
kubectl get sa backend-api -n devtest -o yaml | grep -A2 annotations

# Check pod is using correct SA
kubectl get pods -n devtest -l app=backend-api -o jsonpath='{.items[0].spec.serviceAccountName}'

# Exec into pod and verify identity
kubectl exec -it deploy/backend-api -n devtest -- sh -c '
  curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
'
# Expected: backend-secrets-sa@tesseracthub-480811.iam.gserviceaccount.com
```

---

## Application Integration

### Node.js / TypeScript

Install the SDK:

```bash
npm install @google-cloud/secret-manager @google-cloud/kms
```

Create a secrets client:

```typescript
// src/config/secrets.ts
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';

const client = new SecretManagerServiceClient();
const projectId = process.env.GCP_PROJECT_ID || 'tesseracthub-480811';

// Cache for secrets (refresh periodically in production)
const secretCache = new Map<string, { value: string; expiry: number }>();
const CACHE_TTL = 5 * 60 * 1000; // 5 minutes

export async function getSecret(secretId: string): Promise<string> {
  // Check cache
  const cached = secretCache.get(secretId);
  if (cached && Date.now() < cached.expiry) {
    return cached.value;
  }

  // Fetch from Secret Manager
  const name = `projects/${projectId}/secrets/${secretId}/versions/latest`;

  try {
    const [version] = await client.accessSecretVersion({ name });
    const value = version.payload?.data?.toString() || '';

    // Cache the result
    secretCache.set(secretId, {
      value,
      expiry: Date.now() + CACHE_TTL,
    });

    return value;
  } catch (error) {
    console.error(`Failed to access secret ${secretId}:`, error);
    throw error;
  }
}

export async function getSecretJson<T>(secretId: string): Promise<T> {
  const value = await getSecret(secretId);
  return JSON.parse(value) as T;
}
```

Usage in your application:

```typescript
// src/config/database.ts
import { getSecretJson } from './secrets';

interface DbCredentials {
  host: string;
  port: number;
  database: string;
  username: string;
  password: string;
  sslmode: string;
}

export async function getDatabaseConfig() {
  const creds = await getSecretJson<DbCredentials>('devtest-db-credentials');

  return {
    host: creds.host,
    port: creds.port,
    database: creds.database,
    user: creds.username,
    password: creds.password,
    ssl: creds.sslmode === 'require',
  };
}

// src/index.ts
import { getDatabaseConfig } from './config/database';
import { Pool } from 'pg';

async function main() {
  const dbConfig = await getDatabaseConfig();
  const pool = new Pool(dbConfig);

  // Your application code...
}

main().catch(console.error);
```

### Python

Install the SDK:

```bash
pip install google-cloud-secret-manager google-cloud-kms
```

Create a secrets module:

```python
# config/secrets.py
import json
import os
from functools import lru_cache
from google.cloud import secretmanager

_client = None

def get_client() -> secretmanager.SecretManagerServiceClient:
    """Get or create Secret Manager client."""
    global _client
    if _client is None:
        _client = secretmanager.SecretManagerServiceClient()
    return _client

def get_project_id() -> str:
    """Get GCP project ID from environment or metadata."""
    return os.environ.get('GCP_PROJECT_ID', 'tesseracthub-480811')

@lru_cache(maxsize=32)
def get_secret(secret_id: str, version: str = 'latest') -> str:
    """
    Fetch a secret from Secret Manager.

    Args:
        secret_id: The secret identifier
        version: Version to fetch (default: latest)

    Returns:
        The secret value as a string
    """
    client = get_client()
    project_id = get_project_id()

    name = f"projects/{project_id}/secrets/{secret_id}/versions/{version}"

    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8")

def get_secret_json(secret_id: str, version: str = 'latest') -> dict:
    """Fetch a secret and parse as JSON."""
    return json.loads(get_secret(secret_id, version))

def clear_cache():
    """Clear the secrets cache (call after rotation)."""
    get_secret.cache_clear()
```

Usage:

```python
# config/database.py
from dataclasses import dataclass
from config.secrets import get_secret_json

@dataclass
class DatabaseConfig:
    host: str
    port: int
    database: str
    username: str
    password: str
    sslmode: str

def get_database_config() -> DatabaseConfig:
    """Load database configuration from Secret Manager."""
    creds = get_secret_json('devtest-db-credentials')
    return DatabaseConfig(**creds)

# main.py
import psycopg2
from config.database import get_database_config

def main():
    config = get_database_config()

    conn = psycopg2.connect(
        host=config.host,
        port=config.port,
        dbname=config.database,
        user=config.username,
        password=config.password,
        sslmode=config.sslmode
    )

    # Your application code...

if __name__ == "__main__":
    main()
```

### Go

Install the SDK:

```bash
go get cloud.google.com/go/secretmanager/apiv1
go get cloud.google.com/go/kms/apiv1
```

Create a secrets package:

```go
// pkg/secrets/client.go
package secrets

import (
    "context"
    "encoding/json"
    "fmt"
    "os"
    "sync"
    "time"

    secretmanager "cloud.google.com/go/secretmanager/apiv1"
    "cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
)

var (
    client    *secretmanager.Client
    clientMu  sync.Mutex
    projectID string

    // Cache
    cache   = make(map[string]cacheEntry)
    cacheMu sync.RWMutex
    cacheTTL = 5 * time.Minute
)

type cacheEntry struct {
    value  string
    expiry time.Time
}

func init() {
    projectID = os.Getenv("GCP_PROJECT_ID")
    if projectID == "" {
        projectID = "tesseracthub-480811"
    }
}

func getClient(ctx context.Context) (*secretmanager.Client, error) {
    clientMu.Lock()
    defer clientMu.Unlock()

    if client != nil {
        return client, nil
    }

    var err error
    client, err = secretmanager.NewClient(ctx)
    return client, err
}

// GetSecret fetches a secret from Secret Manager
func GetSecret(ctx context.Context, secretID string) (string, error) {
    // Check cache
    cacheMu.RLock()
    if entry, ok := cache[secretID]; ok && time.Now().Before(entry.expiry) {
        cacheMu.RUnlock()
        return entry.value, nil
    }
    cacheMu.RUnlock()

    // Fetch from Secret Manager
    c, err := getClient(ctx)
    if err != nil {
        return "", fmt.Errorf("failed to create client: %w", err)
    }

    name := fmt.Sprintf("projects/%s/secrets/%s/versions/latest", projectID, secretID)

    result, err := c.AccessSecretVersion(ctx, &secretmanagerpb.AccessSecretVersionRequest{
        Name: name,
    })
    if err != nil {
        return "", fmt.Errorf("failed to access secret %s: %w", secretID, err)
    }

    value := string(result.Payload.Data)

    // Update cache
    cacheMu.Lock()
    cache[secretID] = cacheEntry{
        value:  value,
        expiry: time.Now().Add(cacheTTL),
    }
    cacheMu.Unlock()

    return value, nil
}

// GetSecretJSON fetches a secret and unmarshals it as JSON
func GetSecretJSON[T any](ctx context.Context, secretID string) (T, error) {
    var result T

    value, err := GetSecret(ctx, secretID)
    if err != nil {
        return result, err
    }

    if err := json.Unmarshal([]byte(value), &result); err != nil {
        return result, fmt.Errorf("failed to parse secret %s as JSON: %w", secretID, err)
    }

    return result, nil
}

// ClearCache clears the secrets cache
func ClearCache() {
    cacheMu.Lock()
    cache = make(map[string]cacheEntry)
    cacheMu.Unlock()
}
```

Usage:

```go
// pkg/config/database.go
package config

import (
    "context"
    "yourapp/pkg/secrets"
)

type DatabaseConfig struct {
    Host     string `json:"host"`
    Port     int    `json:"port"`
    Database string `json:"database"`
    Username string `json:"username"`
    Password string `json:"password"`
    SSLMode  string `json:"sslmode"`
}

func GetDatabaseConfig(ctx context.Context) (*DatabaseConfig, error) {
    return secrets.GetSecretJSON[*DatabaseConfig](ctx, "devtest-db-credentials")
}

// main.go
package main

import (
    "context"
    "database/sql"
    "fmt"
    "log"

    _ "github.com/lib/pq"
    "yourapp/pkg/config"
)

func main() {
    ctx := context.Background()

    dbConfig, err := config.GetDatabaseConfig(ctx)
    if err != nil {
        log.Fatalf("Failed to get database config: %v", err)
    }

    dsn := fmt.Sprintf(
        "host=%s port=%d user=%s password=%s dbname=%s sslmode=%s",
        dbConfig.Host, dbConfig.Port, dbConfig.Username,
        dbConfig.Password, dbConfig.Database, dbConfig.SSLMode,
    )

    db, err := sql.Open("postgres", dsn)
    if err != nil {
        log.Fatalf("Failed to connect to database: %v", err)
    }
    defer db.Close()

    // Your application code...
}
```

---

## Helm Chart Integration

### ServiceAccount Template

```yaml
# templates/serviceaccount.yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "myapp.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
```

### Values Configuration

```yaml
# values.yaml
serviceAccount:
  create: true
  name: ""  # Uses release name if empty
  annotations:
    iam.gke.io/gcp-service-account: backend-secrets-sa@tesseracthub-480811.iam.gserviceaccount.com

# Environment variables
env:
  - name: GCP_PROJECT_ID
    value: "tesseracthub-480811"
  - name: DB_SECRET_NAME
    value: "devtest-db-credentials"

# Environment-specific overrides
# values-devtest.yaml
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: backend-secrets-sa@tesseracthub-480811.iam.gserviceaccount.com

# values-prod.yaml
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: backend-secrets-sa@tesseracthub-prod.iam.gserviceaccount.com
```

### Deployment Template

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "myapp.fullname" . }}
  namespace: {{ .Release.Namespace }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "myapp.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "myapp.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "myapp.serviceAccountName" . }}
      automountServiceAccountToken: false
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          env:
            {{- toYaml .Values.env | nindent 12 }}
```

---

## ArgoCD Integration

### Application Manifest

```yaml
# argocd/apps/backend-api.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backend-api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: HEAD
    path: charts/backend-api
    helm:
      valueFiles:
        - values.yaml
        - values-devtest.yaml
      parameters:
        - name: serviceAccount.annotations.iam\.gke\.io/gcp-service-account
          value: backend-secrets-sa@tesseracthub-480811.iam.gserviceaccount.com
  destination:
    server: https://kubernetes.default.svc
    namespace: devtest
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Using KMS for Encryption

For encrypting sensitive data within your application (beyond secrets storage):

### Node.js

```typescript
// src/services/encryption.ts
import { KeyManagementServiceClient } from '@google-cloud/kms';

const client = new KeyManagementServiceClient();

const projectId = process.env.GCP_PROJECT_ID || 'tesseracthub-480811';
const locationId = 'australia-southeast1';
const keyRingId = 'tesseract-devtest-keyring';
const keyId = 'app-encryption-key';

const keyName = client.cryptoKeyPath(projectId, locationId, keyRingId, keyId);

export async function encrypt(plaintext: string): Promise<string> {
  const [result] = await client.encrypt({
    name: keyName,
    plaintext: Buffer.from(plaintext),
  });

  return Buffer.from(result.ciphertext as Uint8Array).toString('base64');
}

export async function decrypt(ciphertext: string): Promise<string> {
  const [result] = await client.decrypt({
    name: keyName,
    ciphertext: Buffer.from(ciphertext, 'base64'),
  });

  return Buffer.from(result.plaintext as Uint8Array).toString();
}

// Usage example: Encrypt PII before storing
async function storePatientData(patientId: string, data: PatientData) {
  const encryptedSSN = await encrypt(data.ssn);
  const encryptedDOB = await encrypt(data.dateOfBirth);

  await db.patients.update({
    where: { id: patientId },
    data: {
      ssn_encrypted: encryptedSSN,
      dob_encrypted: encryptedDOB,
    },
  });
}

// Decrypt when reading
async function getPatientData(patientId: string): Promise<PatientData> {
  const record = await db.patients.findUnique({ where: { id: patientId } });

  return {
    ...record,
    ssn: await decrypt(record.ssn_encrypted),
    dateOfBirth: await decrypt(record.dob_encrypted),
  };
}
```

### Python

```python
# services/encryption.py
import base64
import os
from google.cloud import kms

_client = None

def get_kms_client() -> kms.KeyManagementServiceClient:
    global _client
    if _client is None:
        _client = kms.KeyManagementServiceClient()
    return _client

def get_key_name() -> str:
    project_id = os.environ.get('GCP_PROJECT_ID', 'tesseracthub-480811')
    location = 'australia-southeast1'
    key_ring = 'tesseract-devtest-keyring'
    key = 'app-encryption-key'

    return f"projects/{project_id}/locations/{location}/keyRings/{key_ring}/cryptoKeys/{key}"

def encrypt(plaintext: str) -> str:
    """Encrypt plaintext using Cloud KMS."""
    client = get_kms_client()
    key_name = get_key_name()

    response = client.encrypt(
        request={
            "name": key_name,
            "plaintext": plaintext.encode("utf-8"),
        }
    )

    return base64.b64encode(response.ciphertext).decode("utf-8")

def decrypt(ciphertext: str) -> str:
    """Decrypt ciphertext using Cloud KMS."""
    client = get_kms_client()
    key_name = get_key_name()

    response = client.decrypt(
        request={
            "name": key_name,
            "ciphertext": base64.b64decode(ciphertext),
        }
    )

    return response.plaintext.decode("utf-8")
```

---

## Troubleshooting

### Common Issues and Solutions

#### 1. "Permission Denied" when accessing secrets

```bash
# Check if the GCP SA has the correct IAM bindings
gcloud secrets get-iam-policy devtest-db-credentials \
  --project=tesseracthub-480811

# Verify the Workload Identity binding exists
gcloud iam service-accounts get-iam-policy \
  backend-secrets-sa@tesseracthub-480811.iam.gserviceaccount.com

# Expected output should include:
# - role: roles/iam.workloadIdentityUser
#   members:
#   - serviceAccount:tesseracthub-480811.svc.id.goog[devtest/backend-api]
```

#### 2. Pod cannot get credentials

```bash
# Verify ServiceAccount annotation
kubectl get sa backend-api -n devtest -o yaml

# Check that the pod is using the correct SA
kubectl get pod <pod-name> -n devtest -o jsonpath='{.spec.serviceAccountName}'

# Test from inside the pod
kubectl exec -it <pod-name> -n devtest -- sh

# Inside the pod:
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email

# Should return: backend-secrets-sa@tesseracthub-480811.iam.gserviceaccount.com
# If it returns "default", Workload Identity is not working
```

#### 3. Secret not found

```bash
# Verify secret exists
gcloud secrets describe devtest-db-credentials --project=tesseracthub-480811

# Check if secret has at least one version
gcloud secrets versions list devtest-db-credentials --project=tesseracthub-480811

# If no versions, add one:
echo -n '{"test": "value"}' | gcloud secrets versions add devtest-db-credentials --data-file=-
```

#### 4. KMS permission denied

```bash
# Check KMS key IAM policy
gcloud kms keys get-iam-policy app-encryption-key \
  --keyring=tesseract-devtest-keyring \
  --location=australia-southeast1 \
  --project=tesseracthub-480811

# Verify SA has cryptoKeyEncrypterDecrypter role
```

#### 5. Workload Identity not enabled on node pool

```bash
# Check node pool configuration
gcloud container node-pools describe default \
  --cluster=tesseract-devtest-gke \
  --region=australia-southeast1 \
  --format="value(config.workloadMetadataConfig.mode)"

# Should return: GKE_METADATA
```

### Debug Script

Save this as `debug-workload-identity.sh`:

```bash
#!/bin/bash

NAMESPACE=${1:-devtest}
SA_NAME=${2:-backend-api}
PROJECT_ID=${3:-tesseracthub-480811}

echo "=== Checking Kubernetes ServiceAccount ==="
kubectl get sa $SA_NAME -n $NAMESPACE -o yaml

echo -e "\n=== Checking Pods using this ServiceAccount ==="
kubectl get pods -n $NAMESPACE -o json | \
  jq -r ".items[] | select(.spec.serviceAccountName==\"$SA_NAME\") | .metadata.name"

echo -e "\n=== Checking GCP Service Account IAM Policy ==="
GCP_SA=$(kubectl get sa $SA_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}')
echo "GCP SA: $GCP_SA"
gcloud iam service-accounts get-iam-policy $GCP_SA 2>/dev/null || echo "Could not get IAM policy"

echo -e "\n=== Testing from a Pod ==="
POD=$(kubectl get pods -n $NAMESPACE -l app=$SA_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$POD" ]; then
  echo "Testing in pod: $POD"
  kubectl exec -it $POD -n $NAMESPACE -- sh -c '
    echo "Identity: $(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email)"
    echo "Token available: $(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | head -c 50)..."
  '
else
  echo "No pods found with label app=$SA_NAME"
fi
```

---

## Security Best Practices

### 1. Principle of Least Privilege

Each service should only access secrets it needs:

```hcl
# Good: Fine-grained access
accessible_secrets = [
  "devtest-db-credentials",
  "devtest-jwt-secrets"
]

# Bad: Project-wide access
grant_project_accessor_role = true
```

### 2. Secret Rotation

Implement regular secret rotation:

```bash
# Add new version (keeps old versions for rollback)
gcloud secrets versions add devtest-db-credentials --data-file=new-creds.json

# Disable old version after confirming new version works
gcloud secrets versions disable OLD_VERSION --secret=devtest-db-credentials

# Clear application cache to pick up new version
# (Implement cache refresh in your application)
```

### 3. Audit Logging

Enable and monitor Cloud Audit Logs:

```bash
# View secret access logs
gcloud logging read 'resource.type="secretmanager.googleapis.com/Secret" AND protoPayload.methodName="google.cloud.secretmanager.v1.SecretManagerService.AccessSecretVersion"' \
  --project=tesseracthub-480811 \
  --limit=10
```

### 4. Never Log Secrets

```typescript
// Bad
console.log('Database config:', dbConfig);

// Good
console.log('Database config loaded for host:', dbConfig.host);
```

### 5. Use Environment-Specific Secrets

```
devtest-db-credentials  -> tesseracthub-480811 (dev project)
prod-db-credentials     -> tesseracthub-prod (prod project)
```

### 6. CMEK for Compliance

For regulated workloads, use customer-managed encryption keys:

```hcl
secrets = [
  {
    secret_id = "prod-patient-data-key"
    replication_locations = [
      {
        location     = "australia-southeast1"
        kms_key_name = "projects/tesseracthub-prod/locations/australia-southeast1/keyRings/prod-keyring/cryptoKeys/secrets-key"
      }
    ]
  }
]
```

---

## Quick Reference

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `GCP_PROJECT_ID` | GCP project ID | `tesseracthub-480811` |
| `DB_SECRET_NAME` | Database credentials secret | `devtest-db-credentials` |
| `JWT_SECRET_NAME` | JWT secrets | `devtest-jwt-secrets` |

### gcloud Commands

```bash
# List secrets
gcloud secrets list --project=tesseracthub-480811

# View secret metadata
gcloud secrets describe SECRET_ID --project=tesseracthub-480811

# List versions
gcloud secrets versions list SECRET_ID --project=tesseracthub-480811

# Access secret value
gcloud secrets versions access latest --secret=SECRET_ID --project=tesseracthub-480811

# Add new version
echo -n 'value' | gcloud secrets versions add SECRET_ID --data-file=-

# View KMS keys
gcloud kms keys list --keyring=tesseract-devtest-keyring --location=australia-southeast1
```

### kubectl Commands

```bash
# Create/update ServiceAccount
kubectl apply -f serviceaccount.yaml

# Check SA annotation
kubectl get sa SA_NAME -n NAMESPACE -o jsonpath='{.metadata.annotations}'

# Get pod identity
kubectl exec POD -n NAMESPACE -- curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
```

---

## Required GitHub Secrets

The Terraform workflow requires the following GitHub secrets to be configured in your repository. Secrets are environment-specific and use the format `{ENV}_{SECRET_NAME}` where `ENV` is `DEVTEST`, `PILOT`, or `PROD`.

### Core Infrastructure Secrets

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `GCP_SA_KEY` | GCP Service Account JSON key for Terraform | Yes |
| `GOOGLE_OAUTH_CLIENT_ID` | Google OAuth Client ID for ArgoCD SSO | Yes |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Google OAuth Client Secret for ArgoCD SSO | Yes |
| `ARC_RUNNER_PAT` | GitHub PAT for ARC runners | Yes |
| `ARGOCD_GITHUB_APP_ID` | GitHub App ID for ArgoCD | Yes |
| `ARGOCD_GITHUB_APP_INSTALLATION_ID` | GitHub App Installation ID | Yes |
| `ARGOCD_GITHUB_APP_PRIVATE_KEY` | GitHub App Private Key (PEM) | Yes |
| `CF_API_TOKEN` | Cloudflare API Token for DNS management | Yes |

### Application Secrets (Per Environment)

Replace `{ENV}` with `DEVTEST`, `PILOT`, or `PROD`:

#### Authentication Secrets

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_JWT_SECRET` | JWT signing key for access tokens | Yes |
| `{ENV}_JWT_REFRESH_SECRET` | JWT signing key for refresh tokens | Yes |
| `{ENV}_ENCRYPTION_KEY` | General encryption key for sensitive data | Yes |
| `{ENV}_ADMIN_INIT_SECRET` | Admin initialization secret | No |
| `{ENV}_FANZONE_JWT_SECRET` | FanZone-specific JWT secret | No |

#### Container Registry

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_GHCR_USERNAME` | GitHub Container Registry username | Yes |
| `{ENV}_GHCR_TOKEN` | GitHub Container Registry token (PAT) | Yes |

#### Payment Gateway Secrets

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_RAZORPAY_KEY_ID` | Razorpay API Key ID | No |
| `{ENV}_RAZORPAY_KEY_SECRET` | Razorpay API Key Secret | No |
| `{ENV}_RAZORPAY_WEBHOOK_SECRET` | Razorpay Webhook Secret | No |
| `{ENV}_STRIPE_PUBLISHABLE_KEY` | Stripe Publishable Key | No |
| `{ENV}_STRIPE_SECRET_KEY` | Stripe Secret Key | No |
| `{ENV}_STRIPE_WEBHOOK_SECRET` | Stripe Webhook Secret | No |
| `{ENV}_PAYPAL_CLIENT_ID` | PayPal Client ID | No |
| `{ENV}_PAYPAL_CLIENT_SECRET` | PayPal Client Secret | No |

#### Email Service Secrets

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_SES_SMTP_USERNAME` | AWS SES SMTP Username | No |
| `{ENV}_SES_SMTP_PASSWORD` | AWS SES SMTP Password | No |
| `{ENV}_SENDGRID_API_KEY` | SendGrid API Key | No |

#### External API Secrets

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_CLOUDFLARE_API_TOKEN` | Cloudflare API Token (per environment) | No |
| `{ENV}_MAPBOX_ACCESS_TOKEN` | Mapbox Access Token | No |
| `{ENV}_TYPESENSE_API_KEY` | Typesense API Key | No |
| `{ENV}_RAPIDAPI_KEY` | RapidAPI Key for sports data | No |

#### OAuth Provider Secrets

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_GOOGLE_CLIENT_ID` | Google OAuth Client ID | No |
| `{ENV}_GOOGLE_CLIENT_SECRET` | Google OAuth Client Secret | No |

#### Verification Service Secrets

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_VERIFICATION_API_KEY` | Internal API key for verification service | No |
| `{ENV}_VERIFICATION_EMAIL_API_KEY` | Resend API key for verification emails | No |
| `{ENV}_VERIFICATION_ENCRYPTION_KEY` | Encryption key for verification tokens | No |

#### Internal Service Secrets

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_TENANT_ONBOARDING_API_KEY` | Internal API key for tenant onboarding | No |

#### Database Passwords (Per Namespace)

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_GLOBAL_POSTGRESQL_PASSWORD` | PostgreSQL password for global namespace | Yes |
| `{ENV}_MARKETPLACE_POSTGRESQL_PASSWORD` | PostgreSQL password for marketplace namespace | Yes |
| `{ENV}_HMS_POSTGRESQL_PASSWORD` | PostgreSQL password for HMS namespace | No |
| `{ENV}_FANZONE_POSTGRESQL_PASSWORD` | PostgreSQL password for fanzone namespace | No |
| `{ENV}_HOMECHEF_POSTGRESQL_PASSWORD` | PostgreSQL password for homechef namespace | No |
| `{ENV}_BOOKKEEPING_POSTGRESQL_PASSWORD` | PostgreSQL password for bookkeeping namespace | No |

#### Shipping Carrier Secrets

| Secret Name | Description | Required |
|-------------|-------------|----------|
| `{ENV}_SHIPROCKET_EMAIL` | Shiprocket account email | No |
| `{ENV}_SHIPROCKET_PASSWORD` | Shiprocket account password | No |
| `{ENV}_SHIPPO_API_TOKEN` | Shippo API token | No |
| `{ENV}_DELHIVERY_API_TOKEN` | Delhivery API token | No |
| `{ENV}_DELHIVERY_CLIENT_NAME` | Delhivery client name | No |

### Adding Secrets to GitHub

1. Navigate to your repository on GitHub
2. Go to **Settings** > **Secrets and variables** > **Actions**
3. Click **New repository secret**
4. Add each secret with the appropriate name and value

### Secret Naming Convention

- Environment prefix: `DEVTEST_`, `PILOT_`, `PROD_`
- Secret names use UPPERCASE with underscores
- Example: `DEVTEST_JWT_SECRET`, `PROD_RAZORPAY_KEY_ID`

### GCP Secret Manager Naming

Secrets are stored in GCP Secret Manager with the format:
`{environment}-{secret-name}`

Example: `devtest-jwt-secret`, `prod-razorpay-key-id`

### Generating Secure Secrets

```bash
# Generate a random 64-character secret
openssl rand -base64 48

# Generate a JWT-compatible secret
openssl rand -base64 64 | tr -d '\n'

# Generate an encryption key (32 bytes for AES-256)
openssl rand -base64 32
```
