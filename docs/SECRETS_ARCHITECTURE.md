# Secrets Architecture

This document describes the secrets management architecture for the Tesserix platform across all environments.

## Overview

Secrets live in GCP Secret Manager (created by Terraform from GitHub Secrets)
and are projected into the cluster by the External Secrets Operator.

## Environment Naming Convention

All secrets follow the pattern: `{ENVIRONMENT}_{SECRET_NAME}`

| Environment | Prefix | Description |
|-------------|--------|-------------|
| Development/Test | `DEVTEST_` | Development and testing environment |
| Production | `PROD_` | Production environment |
| Pilot | `PILOT_` | Pre-production/staging environment |

## GitHub Secrets (Source of Truth)

GitHub Secrets serve as the source of truth for all application secrets. Terraform reads these secrets and populates GCP Secret Manager.

### Secret Categories

#### 1. Authentication Secrets
| Secret Name | Description | Used By |
|-------------|-------------|---------|
| `{ENV}_JWT_SECRET` | JWT signing key for access tokens | All services |
| `{ENV}_JWT_REFRESH_SECRET` | JWT signing key for refresh tokens | Auth services |
| `{ENV}_ENCRYPTION_KEY` | General encryption key | Various services |
| `{ENV}_ADMIN_INIT_SECRET` | Admin initialization secret | Setup jobs |
| `{ENV}_FANZONE_JWT_SECRET` | Fanzone-specific JWT secret | Fanzone services |

#### 2. Container Registry
| Secret Name | Description | Used By |
|-------------|-------------|---------|
| `{ENV}_GHCR_USERNAME` | GitHub Container Registry username | All pods |
| `{ENV}_GHCR_TOKEN` | GitHub Container Registry PAT | All pods |

#### 3. Payment Gateways
| Secret Name | Description | Status |
|-------------|-------------|--------|
| `{ENV}_RAZORPAY_KEY_ID` | Razorpay API Key ID | PLACEHOLDER (needs real key) |
| `{ENV}_RAZORPAY_KEY_SECRET` | Razorpay API Key Secret | PLACEHOLDER |
| `{ENV}_RAZORPAY_WEBHOOK_SECRET` | Razorpay Webhook Secret | PLACEHOLDER |
| `{ENV}_STRIPE_PUBLISHABLE_KEY` | Stripe Publishable Key | PLACEHOLDER |
| `{ENV}_STRIPE_SECRET_KEY` | Stripe Secret Key | PLACEHOLDER |
| `{ENV}_STRIPE_WEBHOOK_SECRET` | Stripe Webhook Secret | PLACEHOLDER |
| `{ENV}_PAYPAL_CLIENT_ID` | PayPal Client ID | PLACEHOLDER |
| `{ENV}_PAYPAL_CLIENT_SECRET` | PayPal Client Secret | PLACEHOLDER |

#### 4. Email Services
| Secret Name | Description | Status |
|-------------|-------------|--------|
| `{ENV}_SES_SMTP_USERNAME` | AWS SES SMTP Username | PLACEHOLDER (needs real key) |
| `{ENV}_SES_SMTP_PASSWORD` | AWS SES SMTP Password | PLACEHOLDER |
| `{ENV}_SENDGRID_API_KEY` | SendGrid API Key | PLACEHOLDER |

#### 5. External APIs
| Secret Name | Description | Status |
|-------------|-------------|--------|
| `{ENV}_CLOUDFLARE_API_TOKEN` | Cloudflare API Token | PLACEHOLDER (needs real token) |
| `{ENV}_MAPBOX_ACCESS_TOKEN` | Mapbox Access Token | ✅ DEVTEST has real token |
| `{ENV}_TYPESENSE_API_KEY` | Typesense API Key | Generated per environment |
| `{ENV}_RAPIDAPI_KEY` | RapidAPI Key (Sports Data) | ✅ DEVTEST has real key |

#### 6. OAuth Providers
| Secret Name | Description | Status |
|-------------|-------------|--------|
| `{ENV}_GOOGLE_CLIENT_ID` | Google OAuth Client ID | ✅ DEVTEST has real ID |
| `{ENV}_GOOGLE_CLIENT_SECRET` | Google OAuth Client Secret | ✅ DEVTEST has real secret |

#### 7. Verification Service
| Secret Name | Description | Status |
|-------------|-------------|--------|
| `{ENV}_VERIFICATION_API_KEY` | Internal API key for verification | Generated per environment |
| `{ENV}_VERIFICATION_EMAIL_API_KEY` | Resend API key for emails | ✅ DEVTEST has real key |
| `{ENV}_VERIFICATION_ENCRYPTION_KEY` | Encryption key for tokens | Generated per environment |

#### 8. Internal Services
| Secret Name | Description | Status |
|-------------|-------------|--------|
| `{ENV}_TENANT_ONBOARDING_API_KEY` | Internal API key for tenant onboarding | Generated per environment |

## Third-Party Infrastructure Secrets

PostgreSQL, Redis and the email stack (Postal, Mautic, RabbitMQ) read their
credentials from GCP Secret Manager through ExternalSecrets in each namespace.

## Terraform Integration

### Reading GitHub Secrets
```hcl
data "github_actions_secrets" "tesserix" {
  repository = "tesserix-k8s"
}

# Example: Create GCP Secret from GitHub Secret
resource "google_secret_manager_secret_version" "jwt_secret" {
  secret      = google_secret_manager_secret.jwt_secret.id
  secret_data = data.github_actions_secret.jwt_secret.plaintext_value
}
```

### GCP Secret Manager Structure
```
projects/tesseracthub-480811/secrets/
├── devtest/
│   ├── jwt-secret
│   ├── jwt-refresh-secret
│   ├── razorpay-key-id
│   └── ...
├── prod/
│   ├── jwt-secret
│   ├── jwt-refresh-secret
│   └── ...
└── pilot/
    ├── jwt-secret
    └── ...
```

## Service Integration

### Workload Identity
Services use GCP Workload Identity to access Secret Manager:

```yaml
# Service Account annotation
metadata:
  annotations:
    iam.gke.io/gcp-service-account: app-secrets@tesseracthub-480811.iam.gserviceaccount.com

# Pod spec
spec:
  serviceAccountName: app-service-account
```

### Accessing Secrets in Application
```go
// Using Google Cloud Secret Manager client
client, _ := secretmanager.NewClient(ctx)
secret, _ := client.AccessSecretVersion(ctx, &secretmanagerpb.AccessSecretVersionRequest{
    Name: "projects/tesseracthub-480811/secrets/devtest-jwt-secret/versions/latest",
})
```

## Migration Path

1. **Phase 1 (Current)**: All secrets in GitHub Secrets ✅
2. **Phase 2**: Terraform reads GitHub Secrets → Creates GCP Secret Manager secrets
3. **Phase 3**: Update Helm charts to use GCP Secret Manager via Workload Identity
4. **Phase 4**: Project every secret with the External Secrets Operator

## Placeholder Secrets Checklist

Secrets that need real values before going to production:

### Payment Gateways (All Environments)
- [ ] Razorpay credentials from [Razorpay Dashboard](https://dashboard.razorpay.com)
- [ ] Stripe credentials from [Stripe Dashboard](https://dashboard.stripe.com)
- [ ] PayPal credentials from [PayPal Developer](https://developer.paypal.com)

### Email Services (All Environments)
- [ ] AWS SES SMTP credentials from AWS Console
- [ ] SendGrid API key from [SendGrid](https://sendgrid.com)

### External Services
- [ ] Cloudflare API token for external-dns
- [ ] Mapbox token (PROD/PILOT need separate accounts)
- [ ] RapidAPI key (PROD/PILOT may need separate accounts)

### OAuth (PROD/PILOT)
- [ ] Google OAuth app for production
- [ ] Google OAuth app for pilot

## Security Notes

1. **Never commit secrets to git** - All secrets are in GitHub Secrets or GCP Secret Manager
2. **Rotate secrets regularly** - Use Terraform to rotate and update
3. **Use separate credentials per environment** - DEVTEST, PROD, PILOT have unique values
4. **Audit access** - GCP Secret Manager provides access logging
5. **Principle of least privilege** - Services only get access to secrets they need
