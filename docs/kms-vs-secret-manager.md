# Cloud KMS vs Secret Manager: Understanding the Difference

This document explains the difference between Google Cloud KMS (Key Management Service) and Secret Manager, and how they work together in TesseractHub's infrastructure.

## Overview

**Cloud KMS** and **Secret Manager** are two separate GCP services that serve different but complementary purposes:

| Service | Purpose | What It Stores |
|---------|---------|----------------|
| **Cloud KMS** | Manage cryptographic keys and perform encryption operations | Encryption keys (never exposed) |
| **Secret Manager** | Store and retrieve sensitive data | Actual secret values (passwords, API keys, etc.) |

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         GCP SECURITY SERVICES                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   ┌───────────────────────────────┐      ┌───────────────────────────────┐      │
│   │         CLOUD KMS             │      │       SECRET MANAGER          │      │
│   │   (Key Management Service)    │      │    (Secret Storage Service)   │      │
│   ├───────────────────────────────┤      ├───────────────────────────────┤      │
│   │                               │      │                               │      │
│   │   What it does:               │      │   What it does:               │      │
│   │   • Stores encryption KEYS    │      │   • Stores SECRET VALUES      │      │
│   │   • Performs encrypt/decrypt  │      │   • Version control for       │      │
│   │   • Signs and verifies data   │      │     secrets                   │      │
│   │   • Key rotation              │      │   • Access control per secret │      │
│   │                               │      │   • Audit logging             │      │
│   │   Key NEVER leaves KMS:       │      │                               │      │
│   │   ┌─────────────────────┐     │      │   You retrieve actual value:  │      │
│   │   │  🔐 Encryption Key  │     │      │   ┌─────────────────────┐     │      │
│   │   │  (stored securely)  │     │      │   │  "password123"      │     │      │
│   │   └─────────────────────┘     │      │   │  (returned to app)  │     │      │
│   │                               │      │   └─────────────────────┘     │      │
│   │   You send data TO KMS:       │      │                               │      │
│   │   plaintext ──► KMS ──►       │      │                               │      │
│   │                  ciphertext   │      │                               │      │
│   │                               │      │                               │      │
│   └───────────────┬───────────────┘      └───────────────┬───────────────┘      │
│                   │                                      │                       │
│                   │        HOW THEY INTEGRATE            │                       │
│                   └──────────────┬───────────────────────┘                       │
│                                  │                                               │
│                                  ▼                                               │
│                   ┌──────────────────────────────┐                               │
│                   │   CMEK (Customer-Managed     │                               │
│                   │   Encryption Keys)           │                               │
│                   │                              │                               │
│                   │   Secret Manager uses KMS    │                               │
│                   │   keys to encrypt secrets    │                               │
│                   │   at rest                    │                               │
│                   └──────────────────────────────┘                               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Detailed Comparison

### Cloud KMS (Key Management Service)

**Purpose:** Manage cryptographic keys and perform encryption/decryption operations.

**Key Characteristics:**
- Keys are stored in hardware security modules (HSM) or software
- Keys **never leave** GCP - you send data to KMS for encryption
- Supports symmetric and asymmetric encryption
- Automatic key rotation
- Audit logging of all key usage

**What You Store:**
```
┌─────────────────────────────────────────┐
│  KMS Keyring: tesseract-devtest-keyring │
│  ├── infra-secrets-encryption-key       │
│  ├── infra-database-encryption-key      │
│  ├── customer-data-encryption-key       │
│  └── thirdparty-api-encryption-key      │
└─────────────────────────────────────────┘
```

**Operations:**
| Operation | Description | Example Use Case |
|-----------|-------------|------------------|
| `encrypt()` | Encrypt plaintext data | Encrypt customer PII before storing in DB |
| `decrypt()` | Decrypt ciphertext | Decrypt customer PII when reading from DB |
| `sign()` | Create digital signature | Sign JWT tokens |
| `verify()` | Verify digital signature | Verify webhook authenticity |

**Code Example:**
```javascript
const { KeyManagementServiceClient } = require('@google-cloud/kms');
const kms = new KeyManagementServiceClient();

// Encrypt sensitive data (data goes TO KMS, key stays IN KMS)
async function encryptData(plaintext) {
  const [result] = await kms.encrypt({
    name: 'projects/PROJECT/locations/REGION/keyRings/KEYRING/cryptoKeys/KEY',
    plaintext: Buffer.from(plaintext).toString('base64')
  });
  return result.ciphertext; // Store this encrypted blob in your database
}

// Decrypt data (ciphertext goes TO KMS, key stays IN KMS)
async function decryptData(ciphertext) {
  const [result] = await kms.decrypt({
    name: 'projects/PROJECT/locations/REGION/keyRings/KEYRING/cryptoKeys/KEY',
    ciphertext: ciphertext
  });
  return Buffer.from(result.plaintext, 'base64').toString();
}
```

### Secret Manager

**Purpose:** Securely store, manage, and access sensitive configuration data.

**Key Characteristics:**
- Stores actual secret values (strings, JSON, binary data)
- Version control for secrets
- Per-secret access control via IAM
- Automatic replication across regions
- Integration with Workload Identity for GKE

**What You Store:**
```
┌─────────────────────────────────────────────────────────┐
│  Secret: devtest-infra-db-credentials                   │
│  └── Version 1 (latest):                                │
│      {                                                  │
│        "host": "10.0.0.5",                              │
│        "port": 5432,                                    │
│        "database": "tesseract_db",                      │
│        "username": "app_user",                          │
│        "password": "super-secret-password-123"          │
│      }                                                  │
└─────────────────────────────────────────────────────────┘
```

**Operations:**
| Operation | Description | Example Use Case |
|-----------|-------------|------------------|
| `createSecret()` | Create a new secret | Set up new API key storage |
| `addSecretVersion()` | Add new version | Rotate a password |
| `accessSecretVersion()` | Retrieve secret value | Get DB password at app startup |
| `destroySecretVersion()` | Destroy old version | Clean up after rotation |

**Code Example:**
```javascript
const { SecretManagerServiceClient } = require('@google-cloud/secret-manager');
const client = new SecretManagerServiceClient();

// Retrieve a secret value (you get the actual password/key)
async function getSecret(secretName) {
  const [version] = await client.accessSecretVersion({
    name: `projects/PROJECT/secrets/${secretName}/versions/latest`
  });
  return version.payload.data.toString('utf8');
}

// Usage
const dbConfig = JSON.parse(await getSecret('devtest-infra-db-credentials'));
// dbConfig = { host: "10.0.0.5", port: 5432, password: "super-secret-password-123", ... }
```

## How They Work Together

### Integration via CMEK

Secret Manager can use KMS keys to encrypt secrets at rest. This is called **Customer-Managed Encryption Keys (CMEK)**.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        CMEK INTEGRATION FLOW                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   1. You create a secret in Secret Manager                                  │
│      ┌─────────────────────────────────────────┐                            │
│      │  Secret: devtest-infra-db-credentials   │                            │
│      │  Value: {"password": "abc123"}          │                            │
│      └─────────────────────────────────────────┘                            │
│                          │                                                  │
│                          ▼                                                  │
│   2. Secret Manager sends the value to KMS for encryption                   │
│      ┌─────────────────────────────────────────┐                            │
│      │  KMS Key: infra-secrets-encryption-key  │                            │
│      │  Operation: encrypt(secret_value)       │                            │
│      └─────────────────────────────────────────┘                            │
│                          │                                                  │
│                          ▼                                                  │
│   3. Encrypted secret is stored in Secret Manager                           │
│      ┌─────────────────────────────────────────┐                            │
│      │  Stored: [encrypted blob]               │                            │
│      │  (encrypted with your KMS key)          │                            │
│      └─────────────────────────────────────────┘                            │
│                          │                                                  │
│                          ▼                                                  │
│   4. When you access the secret, it's decrypted automatically               │
│      ┌─────────────────────────────────────────┐                            │
│      │  You call: accessSecretVersion()        │                            │
│      │  You receive: {"password": "abc123"}    │                            │
│      └─────────────────────────────────────────┘                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Typical Application Usage

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        APPLICATION FLOW                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────┐                                                       │
│   │  Your App Pod   │                                                       │
│   └────────┬────────┘                                                       │
│            │                                                                │
│   ┌────────┴────────────────────────────────────────────────────────┐       │
│   │                                                                 │       │
│   │  STEP 1: Get database password from Secret Manager             │       │
│   │  ─────────────────────────────────────────────────             │       │
│   │                                                                 │       │
│   │  const dbPassword = await secretManager.accessSecretVersion({   │       │
│   │    name: '.../devtest-infra-db-credentials/versions/latest'     │       │
│   │  });                                                            │       │
│   │  // Returns: "super-secret-password-123"                        │       │
│   │                                                                 │       │
│   │  Use this to connect to PostgreSQL                              │       │
│   │                                                                 │       │
│   └─────────────────────────────────────────────────────────────────┘       │
│            │                                                                │
│   ┌────────┴────────────────────────────────────────────────────────┐       │
│   │                                                                 │       │
│   │  STEP 2: Encrypt customer PII using KMS before storing          │       │
│   │  ───────────────────────────────────────────────────           │       │
│   │                                                                 │       │
│   │  const encryptedSSN = await kms.encrypt({                       │       │
│   │    name: '.../customer-data-encryption-key',                    │       │
│   │    plaintext: customerSSN                                       │       │
│   │  });                                                            │       │
│   │  // Returns: encrypted blob                                     │       │
│   │                                                                 │       │
│   │  Store encryptedSSN in database (not the raw SSN)               │       │
│   │                                                                 │       │
│   └─────────────────────────────────────────────────────────────────┘       │
│            │                                                                │
│   ┌────────┴────────────────────────────────────────────────────────┐       │
│   │                                                                 │       │
│   │  STEP 3: Decrypt customer PII when needed                       │       │
│   │  ────────────────────────────────────────                      │       │
│   │                                                                 │       │
│   │  const decryptedSSN = await kms.decrypt({                       │       │
│   │    name: '.../customer-data-encryption-key',                    │       │
│   │    ciphertext: encryptedSSN                                     │       │
│   │  });                                                            │       │
│   │  // Returns: original SSN                                       │       │
│   │                                                                 │       │
│   └─────────────────────────────────────────────────────────────────┘       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## When to Use Which

### Use Secret Manager When:

| Scenario | Example |
|----------|---------|
| Storing passwords | Database passwords, admin credentials |
| Storing API keys | Stripe API key, SendGrid API key |
| Storing connection strings | Redis URL, MongoDB connection string |
| Storing certificates | TLS certificates, CA certificates |
| Storing configuration | JWT secrets, encryption keys (the actual key bytes) |

### Use Cloud KMS When:

| Scenario | Example |
|----------|---------|
| Encrypting data at rest | Encrypt customer PII before storing in database |
| Signing data | Sign JWT tokens, sign webhook payloads |
| Envelope encryption | Encrypt data encryption keys (DEKs) |
| CMEK for other services | Encrypt Cloud Storage, BigQuery, Secret Manager |
| Regulatory compliance | HIPAA, PCI-DSS requiring HSM-backed keys |

## TesseractHub Three-Tier Implementation

In our infrastructure, we use both services organized into three tiers:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      THREE-TIER SECRETS ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  TIER 1: INFRASTRUCTURE                                                     │
│  ┌────────────────────────────┐    ┌────────────────────────────┐          │
│  │  Secret Manager            │    │  Cloud KMS                 │          │
│  │  ├─ db-credentials         │◄──►│  ├─ infra-secrets-enc-key  │          │
│  │  ├─ jwt-secrets            │    │  ├─ infra-database-enc-key │          │
│  │  └─ encryption-keys        │    │  └─ infra-signing-key      │          │
│  └────────────────────────────┘    └────────────────────────────┘          │
│                                                                             │
│  TIER 2: CUSTOMER                                                           │
│  ┌────────────────────────────┐    ┌────────────────────────────┐          │
│  │  Secret Manager            │    │  Cloud KMS                 │          │
│  │  ├─ tenant-configs         │◄──►│  ├─ customer-secrets-key   │          │
│  │  ├─ customer-api-keys      │    │  ├─ customer-data-enc-key  │          │
│  │  └─ customer-credentials   │    │  └─ customer-signing-key   │          │
│  └────────────────────────────┘    └────────────────────────────┘          │
│                                                                             │
│  TIER 3: THIRD-PARTY                                                        │
│  ┌────────────────────────────┐    ┌────────────────────────────┐          │
│  │  Secret Manager            │    │  Cloud KMS                 │          │
│  │  ├─ email (SendGrid)       │◄──►│  ├─ thirdparty-secrets-key │          │
│  │  ├─ payment (Stripe)       │    │  ├─ thirdparty-api-enc-key │          │
│  │  └─ messaging (FCM/Twilio) │    │  └─ thirdparty-signing-key │          │
│  └────────────────────────────┘    └────────────────────────────┘          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Pricing Comparison

| Service | Pricing Model | Approximate Cost |
|---------|---------------|------------------|
| **Secret Manager** | Per secret per month + per access | ~$0.06/secret/month + $0.03/10K accesses |
| **Cloud KMS** | Per key version per month + per operation | ~$0.06/key/month + $0.03/10K operations |

Both services are very cost-effective compared to managing your own HSM or secrets infrastructure.

## Security Best Practices

### Secret Manager Best Practices

1. **Use Workload Identity** - Never store service account keys
2. **Enable audit logging** - Track all secret access
3. **Use secret versions** - Never modify secrets in place
4. **Set up rotation** - Regularly rotate sensitive secrets
5. **Apply least privilege** - Grant access per-secret, not project-wide

### Cloud KMS Best Practices

1. **Use automatic key rotation** - 90 days for symmetric keys
2. **Separate keys by purpose** - Don't reuse keys across different data types
3. **Use HSM for production** - Hardware-backed keys for compliance
4. **Enable audit logging** - Track all encryption/decryption operations
5. **Implement envelope encryption** - For large data, encrypt DEKs with KEKs

## Quick Reference Commands

### Secret Manager

```bash
# List all secrets
gcloud secrets list

# Create a secret
echo -n "my-password" | gcloud secrets create my-secret --data-file=-

# Access a secret
gcloud secrets versions access latest --secret=my-secret

# Add a new version (rotate)
echo -n "new-password" | gcloud secrets versions add my-secret --data-file=-
```

### Cloud KMS

```bash
# List keyrings
gcloud kms keyrings list --location=australia-southeast1

# List keys in a keyring
gcloud kms keys list --keyring=tesseract-devtest-keyring --location=australia-southeast1

# Encrypt data
echo -n "sensitive data" | gcloud kms encrypt \
  --keyring=tesseract-devtest-keyring \
  --key=infra-secrets-encryption-key \
  --location=australia-southeast1 \
  --plaintext-file=- \
  --ciphertext-file=encrypted.bin

# Decrypt data
gcloud kms decrypt \
  --keyring=tesseract-devtest-keyring \
  --key=infra-secrets-encryption-key \
  --location=australia-southeast1 \
  --ciphertext-file=encrypted.bin \
  --plaintext-file=-
```

## Summary

| Aspect | Secret Manager | Cloud KMS |
|--------|----------------|-----------|
| **Stores** | Secret values | Encryption keys |
| **You get back** | The actual secret | Encrypted/decrypted data |
| **Key exposure** | N/A | Key never leaves GCP |
| **Primary use** | Configuration secrets | Data encryption |
| **Versioning** | Secret versions | Key versions |
| **Integration** | Uses KMS for CMEK | Encrypts for Secret Manager |

**Think of it this way:**
- **Secret Manager** = Your password manager (stores passwords)
- **Cloud KMS** = Your encryption engine (encrypts/decrypts data, keys stay locked away)

## Related Documentation

- [Three-Tier Secrets Architecture](./three-tier-secrets-architecture.md)
- [Secrets Management Guide](./secrets-management.md)
- [GCP Secret Manager Docs](https://cloud.google.com/secret-manager/docs)
- [GCP Cloud KMS Docs](https://cloud.google.com/kms/docs)
