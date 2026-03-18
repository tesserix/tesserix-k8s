# Placeholder Secrets - Action Required

The following secrets contain **PLACEHOLDER** values and need to be updated with real credentials.

## Marketplace Namespace

### Payment Gateway Secrets (Required for payment processing)

| Secret Name | Keys | Status |
|-------------|------|--------|
| `razorpay-credentials` | RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET, RAZORPAY_WEBHOOK_SECRET | ⚠️ PLACEHOLDER |
| `stripe-credentials` | STRIPE_PUBLISHABLE_KEY, STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET | ⚠️ PLACEHOLDER |
| `paypal-credentials` | PAYPAL_CLIENT_ID, PAYPAL_CLIENT_SECRET | ⚠️ PLACEHOLDER |
| `tenant-onboarding-api-key` | INTERNAL_API_KEY | ⚠️ PLACEHOLDER |

## Identity Namespaces

### identity-customer & identity-internal

| Secret Name | Keys | Status |
|-------------|------|--------|
| `keycloak-google-sso` | client-id, client-secret | ⚠️ PLACEHOLDER (Google OAuth) |

Note: `keycloak-admin-credentials`, `keycloak-db-credentials`, and `keycloak-redis-credentials` contain dev passwords.

## Email Namespace

| Secret Name | Keys | Status |
|-------------|------|--------|
| `sendgrid-credentials` | SENDGRID_API_KEY | ⚠️ PLACEHOLDER |
| `ses-smtp-credentials` | SES_SMTP_USERNAME, SES_SMTP_PASSWORD | ⚠️ PLACEHOLDER |

Note: `mysql-credentials`, `postal-credentials`, `postal-smtp-credentials`, `mautic-credentials`, `rabbitmq-credentials` contain dev passwords.

## External-DNS Namespace

| Secret Name | Keys | Status |
|-------------|------|--------|
| `external-dns-cloudflare` | api-token | ⚠️ PLACEHOLDER (Cloudflare API token) |

## Typesense Namespace

| Secret Name | Keys | Status |
|-------------|------|--------|
| `typesense-secrets` | api-key | Dev API key (can be used as-is for dev) |

## How to Update Secrets

1. Create a plain secret YAML file with actual values:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: razorpay-credentials
  namespace: marketplace
type: Opaque
stringData:
  RAZORPAY_KEY_ID: "your-actual-key-id"
  RAZORPAY_KEY_SECRET: "your-actual-key-secret"
  RAZORPAY_WEBHOOK_SECRET: "your-actual-webhook-secret"
```

2. Seal the secret:
```bash
kubeseal --controller-namespace kube-system --controller-name sealed-secrets \
  -o yaml < plain-secret.yaml > sealedsecret/marketplace/razorpay-credentials.yaml
```

3. Apply and commit:
```bash
kubectl apply -f sealedsecret/marketplace/razorpay-credentials.yaml
git add sealedsecret/marketplace/razorpay-credentials.yaml
git commit -m "chore: update razorpay credentials with real values"
git push
```

## Working Secrets

These secrets have been successfully re-sealed and contain working dev values:

### Global Namespace
- `ghcr-secret` - GitHub Container Registry credentials
- `jwt-secret` - JWT signing key
- `postgresql-password` - PostgreSQL password
- `redis-password` - Redis password
- `redis` - Redis secret (for services expecting 'redis' secret name)
- `verification-api-key` - Verification service API key
- `verification-secrets` - Verification service secrets
- `location-service-address-secrets` - Mapbox API token

### Marketplace Namespace
- `ghcr-secret` - GitHub Container Registry credentials
- `jwt-secret` - JWT signing key
- `postgresql-password` - PostgreSQL password
- `redis-password` - Redis password

### Bookkeeping Namespace
- `ghcr-secret` - GitHub Container Registry credentials
- `jwt-secret` - JWT signing key
- `postgresql-password` - PostgreSQL password
- `redis-password` - Redis password

## Known Issues

### Bookkeeping Services
Some bookkeeping services (core, customer, invoice, report) are missing `JWT_SECRET` environment variable in their Helm charts. The Helm values need to be updated to include:
```yaml
env:
  JWT_SECRET:
    valueFrom:
      secretKeyRef:
        name: jwt-secret
        key: jwt-secret
```

### Document Service (Global)
Requires GCP credentials for cloud storage. The service is configured to use GCP storage provider but lacks authentication.

### External-DNS
Will not function until the Cloudflare API token is replaced with a real token.

## Notes

- The old sealed secrets were encrypted with a previous sealed-secrets controller key that no longer exists
- All secrets were re-sealed with the current controller key
- Payment gateway credentials (Razorpay, Stripe, PayPal) need to be obtained from respective dashboards
- Services will start but payment processing will fail until real credentials are provided
