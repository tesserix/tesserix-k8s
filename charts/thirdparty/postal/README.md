# Postal SMTP Server Helm Chart

This Helm chart deploys [Postal](https://postalserver.io/), an open-source mail delivery platform, with AWS SES SMTP relay for outbound email delivery.

## Architecture

```
┌─────────────────────┐
│ Notification Service │
│   (marketplace ns)   │
└──────────┬──────────┘
           │ HTTP POST /api/v1/messages/send
           ▼
┌─────────────────────┐
│    Postal Web       │
│   (email ns:5000)   │
└──────────┬──────────┘
           │ RabbitMQ Queue
           ▼
┌─────────────────────────────────────────┐
│           Postal Worker Pod             │
│  ┌─────────────┐    ┌────────────────┐  │
│  │   Worker    │───▶│ Postfix Sidecar│  │
│  │ Container   │    │  (smtp-relay)  │  │
│  └─────────────┘    └───────┬────────┘  │
│                             │           │
└─────────────────────────────┼───────────┘
                              │ SMTP (587)
                              ▼
                    ┌─────────────────────┐
                    │      AWS SES        │
                    │ (ap-south-1 region) │
                    └──────────┬──────────┘
                               │
                               ▼
                         Recipient Inbox
```

## Why Postfix Sidecar?

1. **GCP blocks port 25**: Google Cloud blocks outbound SMTP (port 25) for direct email delivery
2. **Postal doesn't support authenticated SMTP relay**: Postal's `smtp_relays` config only supports unauthenticated SMTP
3. **Solution**: Postfix sidecar handles SMTP authentication to AWS SES (port 587)

## Prerequisites

Before deploying Postal, ensure you have:

1. **MySQL database** running in the cluster
2. **RabbitMQ** running in the cluster
3. **AWS SES account** with:
   - Verified domain or email addresses
   - SMTP credentials (NOT IAM credentials)
   - Production access (if sending to non-verified addresses)
4. **Sealed Secrets controller** installed in the cluster

---

## Step-by-Step Production Setup

### Step 1: Generate AWS SES SMTP Credentials

1. Go to AWS Console → SES → SMTP Settings
2. Click "Create SMTP credentials"
3. Note down:
   - **SMTP Username**: 20-character `AKIA`-prefixed string (e.g., `AKIAEXAMPLE1234567890`)
   - **SMTP Password**: 44-character base64 string (e.g., `EXAMPLE/base64/value+for+ses+smtp+password=`)

> **Important**: SMTP credentials are different from IAM access keys. Generate them from the SES Console.

### Step 2: Store Credentials in Secret Managers

#### 2.1 GCP Secret Manager

```bash
# Set your project and environment
PROJECT_ID="your-gcp-project"
ENV="prod"  # or "devtest"

# Create/Update username secret
echo -n "YOUR_SES_SMTP_USERNAME" | gcloud secrets versions add ${ENV}-ses-smtp-username \
  --project=${PROJECT_ID} --data-file=-

# Create/Update password secret
echo -n "YOUR_SES_SMTP_PASSWORD" | gcloud secrets versions add ${ENV}-ses-smtp-password \
  --project=${PROJECT_ID} --data-file=-

# Also update relay-specific secrets (used by Postal)
echo -n "YOUR_SES_SMTP_USERNAME" | gcloud secrets versions add ${ENV}-ses-smtp-relay-username \
  --project=${PROJECT_ID} --data-file=-

echo -n "YOUR_SES_SMTP_PASSWORD" | gcloud secrets versions add ${ENV}-ses-smtp-relay-password \
  --project=${PROJECT_ID} --data-file=-
```

#### 2.2 GitHub Secrets

```bash
# For CI/CD pipelines
echo -n "YOUR_SES_SMTP_USERNAME" | gh secret set SES_SMTP_USERNAME --repo YOUR_ORG/YOUR_REPO
echo -n "YOUR_SES_SMTP_PASSWORD" | gh secret set SES_SMTP_PASSWORD --repo YOUR_ORG/YOUR_REPO

# For production (if separate)
echo -n "YOUR_SES_SMTP_USERNAME" | gh secret set PROD_SES_SMTP_USERNAME --repo YOUR_ORG/YOUR_REPO
echo -n "YOUR_SES_SMTP_PASSWORD" | gh secret set PROD_SES_SMTP_PASSWORD --repo YOUR_ORG/YOUR_REPO
```

### Step 3: Generate Kubernetes SealedSecret

The Helm chart uses SealedSecrets for Kubernetes secret management with ArgoCD.

```bash
# Get the kubeseal certificate (if not using controller discovery)
kubeseal --fetch-cert --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets > /tmp/sealed-secrets.pem

# Generate encrypted SES SMTP password
echo -n "YOUR_SES_SMTP_PASSWORD" | kubeseal --raw \
  --namespace email \
  --name ses-smtp-credentials \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --from-file=/dev/stdin

# Copy the output (long base64 string) for values.yaml
```

### Step 4: Update values.yaml

Edit `values.yaml` with your environment-specific configuration:

```yaml
# Postal configuration
postal:
  webHostname: "postal.yourdomain.com"      # Your Postal web UI hostname
  smtpHostname: "smtp.yourdomain.com"       # Your SMTP hostname

# SMTP relay settings
relay:
  enabled: true
  provider: "ses"  # or "sendgrid"

  ses:
    host: "email-smtp.ap-south-1.amazonaws.com"  # Your SES region
    port: 587
    username: "YOUR_SES_SMTP_USERNAME"           # From Step 1
    existingSecret: "ses-smtp-credentials"
    existingSecretPasswordKey: "SES_SMTP_PASSWORD"
    sealedSecret:
      enabled: true
      encryptedData:
        SES_SMTP_PASSWORD: "YOUR_SEALED_SECRET_VALUE"  # From Step 3

# Init setup configuration
initSetup:
  enabled: true
  admin:
    email: "admin@yourdomain.com"
    firstName: "Admin"
    lastName: "User"
  organization:
    name: "YourOrg"
    permalink: "yourorg"
  server:
    name: "Notifications"
    permalink: "notifications"
  domains:
    - name: "yourdomain.com"
      autoVerify: true  # Set to false in prod and configure DNS properly
```

### Step 5: Configure DNS Records (Production)

For production, configure these DNS records for your sending domain:

| Type | Name | Value |
|------|------|-------|
| MX | @ | `smtp.yourdomain.com` (priority 10) |
| TXT | @ | `v=spf1 include:amazonses.com ~all` |
| TXT | postal._domainkey | DKIM public key from Postal UI |
| CNAME | rp | Return path domain |
| CNAME | track | Tracking domain |

### Step 6: Deploy with ArgoCD

```bash
# Commit and push changes
git add charts/thirdparty/postal/values.yaml
git commit -m "feat(postal): configure for production"
git push

# ArgoCD will auto-sync, or manually sync:
kubectl -n argocd patch application postal --type=merge \
  -p '{"operation":{"initiatedBy":{"username":"cli"},"sync":{"syncStrategy":{"hook":{}}}}}'

# If ArgoCD is stuck OutOfSync, apply directly:
cd charts/thirdparty/postal
helm template postal . -n email | kubectl apply -f -
```

### Step 7: Verify Deployment

```bash
# Check pods are running
kubectl get pods -n email -l app.kubernetes.io/name=postal

# Verify SES credentials in Postfix sidecar
kubectl exec -n email deployment/postal-worker -c postfix-relay -- cat /etc/postfix/sasl_passwd
# Should show: [email-smtp.region.amazonaws.com]:587 USERNAME:PASSWORD

# Check Postal worker logs
kubectl logs -n email deployment/postal-worker -c worker --tail=50

# Check Postfix logs
kubectl logs -n email deployment/postal-worker -c postfix-relay --tail=50
```

### Step 8: Test Email Delivery

```bash
# Send test email via notification service
kubectl exec -n marketplace deployment/notification-hub -c istio-proxy -- \
  curl -s -X POST http://notification-service:8090/api/v1/notifications/send \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: your-tenant" \
  -d '{
    "channel": "EMAIL",
    "recipientEmail": "test@example.com",
    "subject": "Postal Test Email",
    "body": "This is a test email from Postal via AWS SES.",
    "priority": "HIGH"
  }'

# Check notification status
kubectl exec -n marketplace deployment/notification-hub -c istio-proxy -- \
  curl -s "http://notification-service:8090/api/v1/notifications/NOTIFICATION_ID" \
  -H "X-Tenant-ID: your-tenant" | jq '.data.status'
```

---

## Troubleshooting

### "No SMTP servers were available"

**Cause**: Postal's DNS resolver (`Resolv::DNS`) doesn't read `/etc/hosts`

**Solution**: The chart includes a Ruby initializer (`smtp_relay_resolver.rb`) that patches the DNS resolution to use `Socket.getaddrinfo` which reads `/etc/hosts`. Ensure the worker pod has `hostAliases` configured:

```yaml
hostAliases:
  - ip: "127.0.0.1"
    hostnames:
      - "smtp-relay"
```

### "535 Authentication Credentials Invalid"

**Cause**: Wrong SES SMTP credentials

**Solution**:
1. Verify you're using SMTP credentials (not IAM access keys)
2. Generate new SMTP credentials from AWS SES Console
3. Update all secret stores (GCP, GitHub, SealedSecret)
4. Redeploy the worker pod

### "Domain not verified" in Postal

**Cause**: Sender domain not configured in Postal

**Solution**:
1. Add domain in Postal UI: Settings → Domains → Add Domain
2. Or configure in `values.yaml`:
   ```yaml
   initSetup:
     domains:
       - name: "yourdomain.com"
         autoVerify: true
   ```

### ArgoCD stuck OutOfSync

**Cause**: Sync conflicts or failed hooks

**Solution**:
```bash
# Force refresh
kubectl -n argocd patch application postal --type=merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Or apply directly with Helm
helm template postal . -n email | kubectl apply -f -
```

### Postfix SASL warnings

These warnings are harmless and can be ignored:
```
sasl-xoauth2: Unable to open config file /etc/sasl-xoauth2.conf: No such file or directory
```

---

## Configuration Reference

### Key Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `relay.enabled` | Enable SMTP relay via Postfix sidecar | `true` |
| `relay.provider` | Relay provider (`ses` or `sendgrid`) | `ses` |
| `relay.ses.host` | SES SMTP endpoint | `email-smtp.ap-south-1.amazonaws.com` |
| `relay.ses.port` | SES SMTP port | `587` |
| `relay.ses.username` | SES SMTP username | `` |
| `initSetup.enabled` | Auto-configure admin, org, server | `true` |
| `initSetup.domains` | Domains to auto-configure | `[]` |

### SES Regional Endpoints

| Region | Endpoint |
|--------|----------|
| US East (N. Virginia) | `email-smtp.us-east-1.amazonaws.com` |
| US West (Oregon) | `email-smtp.us-west-2.amazonaws.com` |
| EU (Ireland) | `email-smtp.eu-west-1.amazonaws.com` |
| Asia Pacific (Mumbai) | `email-smtp.ap-south-1.amazonaws.com` |
| Asia Pacific (Sydney) | `email-smtp.ap-southeast-2.amazonaws.com` |

---

## Files Modified During Setup

1. `values.yaml` - Main configuration (SES credentials, domains)
2. `templates/deployment-worker.yaml` - Postfix sidecar, hostAliases
3. `templates/secret-config.yaml` - Ruby initializers for DNS resolution
4. `templates/job-init-setup.yaml` - Auto-setup of admin, org, domains
5. `templates/sealedsecret-ses.yaml` - SealedSecret for SES credentials

---

## Quick Reference Commands

```bash
# Check Postal pods
kubectl get pods -n email -l app.kubernetes.io/instance=postal

# View worker logs
kubectl logs -n email deployment/postal-worker -c worker -f

# View Postfix logs
kubectl logs -n email deployment/postal-worker -c postfix-relay -f

# Verify SES credentials
kubectl exec -n email deployment/postal-worker -c postfix-relay -- cat /etc/postfix/sasl_passwd

# Restart worker to pick up new config
kubectl rollout restart deployment/postal-worker -n email

# Access Postal Web UI
kubectl port-forward -n email svc/postal-web 5000:5000
# Then visit http://localhost:5000
```
