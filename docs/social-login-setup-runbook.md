# Social Login Setup Runbook

Operational runbook for configuring social login IDPs across both environments.
Run this for **DevTest first**, then repeat for **Prod** after verification.

---

## Environment Reference

| | DevTest | Prod |
|---|---|---|
| **Google OAuth Client ID** | `541265339192-ahke854q5vaoqkjcg3b6oam4bipf1uo0` | `<PROD_GOOGLE_CLIENT_ID>` |
| **Internal Keycloak URL** | `devtest-internal-idp.tesserix.app` | `internal-idp.mark8ly.com` |
| **Customer Keycloak URL** | `devtest-customer-idp.tesserix.app` | `identity.fanzonebattleground.com` |
| **GCP Secret Prefix** | `devtest-` | `prod-` |
| **GCP Project** | `tesseracthub-480811` | `tesseracthub-480811` |
| **K8s Namespace (customer)** | `identity-customer` | `identity` |
| **K8s Namespace (internal)** | `identity-internal` | `identity-internal` |

---

## Phase 0: Provider Console Setup

### 0a. Google Console — Add Internal Realm Redirect URIs

> Repeat for each environment's OAuth Client ID.

1. Go to **GCP Console > APIs & Services > Credentials**
2. Edit the OAuth 2.0 Client for the target environment
3. Under **Authorized redirect URIs**, add (if missing):

**DevTest** (Client ID: `541265339192-ahke854q5vaoqkjcg3b6oam4bipf1uo0`):
```
https://devtest-internal-idp.tesserix.app/realms/tesserix-internal/broker/google/endpoint
```

**Prod** (Client ID: `<PROD_GOOGLE_CLIENT_ID>`):
```
https://internal-idp.mark8ly.com/realms/tesserix-internal/broker/google/endpoint
```

4. Verify these **customer realm** URIs already exist (added by `admin-sso-job`):

**DevTest:**
```
https://devtest-customer-idp.tesserix.app/realms/tesserix-customer/broker/google/endpoint
```

**Prod:**
```
https://identity.fanzonebattleground.com/realms/tesserix-customer/broker/google/endpoint
```

5. Also verify the **master realm** URIs exist (used for Keycloak admin console SSO):

**DevTest:**
```
https://devtest-internal-idp.tesserix.app/realms/master/broker/google/endpoint
https://devtest-customer-idp.tesserix.app/realms/master/broker/google/endpoint
```

**Prod:**
```
https://internal-idp.mark8ly.com/realms/master/broker/google/endpoint
https://identity.fanzonebattleground.com/realms/master/broker/google/endpoint
```

6. Click **Save**

---

### 0b. Apple Developer Console

> Apple credentials are shared across environments. The Service ID's return URLs cover both.

1. Go to **Apple Developer > Certificates, Identifiers & Profiles > Identifiers**

2. Click **+** > Select **Service IDs** > Continue

3. Fill in:
   - **Description:** `Mark8ly Sign In`
   - **Identifier:** `com.mark8ly.signin`
   - Click **Continue** > **Register**

4. Click on the newly created Service ID > Check **Sign in with Apple** > **Configure**

5. Add **Domains and Subdomains:**
   ```
   devtest-customer-idp.tesserix.app
   identity.fanzonebattleground.com
   ```

6. Add **Return URLs:**
   ```
   https://devtest-customer-idp.tesserix.app/realms/tesserix-customer/broker/apple/endpoint
   https://identity.fanzonebattleground.com/realms/tesserix-customer/broker/apple/endpoint
   ```

7. Click **Save** > **Continue** > **Save**

8. Create a **Key** for Sign in with Apple:
   - Go to **Keys** > Click **+**
   - **Key Name:** `Mark8ly Sign In Key`
   - Check **Sign in with Apple** > **Configure** > Select the primary App ID
   - Click **Continue** > **Register**
   - **Download the .p8 file immediately** (can only be downloaded once)

9. Record these values:

   | Value | Where to find | Example |
   |---|---|---|
   | `APPLE_TEAM_ID` | Top-right of Apple Developer account page | `ABC123DEF4` |
   | `APPLE_KEY_ID` | Keys list, shown after creating the key | `XYZ789KEY0` |
   | `APPLE_SERVICE_ID` | The identifier from step 3 | `com.mark8ly.signin` |
   | `.p8 key file` | Downloaded in step 8 | `AuthKey_XYZ789KEY0.p8` |

---

### 0c. Meta (Facebook) Developer Console

> Use separate Facebook Apps for DevTest and Prod (different App Secrets).

1. Go to **[Meta for Developers](https://developers.facebook.com/apps/)**

2. Click **Create App** > Select **Authenticate and request data from users with Facebook Login** > **Next**

3. Fill in:
   - **App Name:** `Mark8ly Store Login` (DevTest) / `Mark8ly Store Login Prod` (Prod)
   - **App Contact Email:** your admin email
   - Click **Create App**

4. In the app dashboard, go to **Facebook Login > Settings**

5. Add **Valid OAuth Redirect URIs:**

   **DevTest app:**
   ```
   https://devtest-customer-idp.tesserix.app/realms/tesserix-customer/broker/facebook/endpoint
   ```

   **Prod app:**
   ```
   https://identity.fanzonebattleground.com/realms/tesserix-customer/broker/facebook/endpoint
   ```

6. Click **Save Changes**

7. Record credentials from **App Settings > Basic:**

   | Value | DevTest | Prod |
   |---|---|---|
   | `FACEBOOK_APP_ID` | `<devtest-app-id>` | `<prod-app-id>` |
   | `FACEBOOK_APP_SECRET` | Click **Show** | Click **Show** |

8. **For Prod only:** Switch app to **Live** mode
   - Requires: Privacy Policy URL, Terms of Service URL
   - Go to **App Settings > Basic** > fill in Privacy Policy URL
   - Toggle from **Development** to **Live** at the top of the dashboard

---

## Phase 1: GCP Secret Manager — Create Secrets

> Run once per environment. Replace `ENV_PREFIX` with `devtest` or `prod`.

### 1a. Set Environment Variables

```bash
# Choose environment
ENV_PREFIX="devtest"  # or "prod"
GCP_PROJECT="tesseracthub-480811"

# Apple credentials (from Phase 0b)
APPLE_TEAM_ID="<your-team-id>"
APPLE_KEY_ID="<your-key-id>"
APPLE_SERVICE_ID="com.mark8ly.signin"
APPLE_P8_FILE="AuthKey_<KEY_ID>.p8"

# Facebook credentials (from Phase 0c — use the correct app for each env)
FACEBOOK_APP_ID="<your-app-id>"
FACEBOOK_APP_SECRET="<your-app-secret>"
```

### 1b. Create Apple Secrets

```bash
# Create secrets
for key in apple-team-id apple-key-id apple-service-id apple-private-key; do
  gcloud secrets create ${ENV_PREFIX}-${key} \
    --project=${GCP_PROJECT} \
    --replication-policy=automatic \
    2>/dev/null || echo "Secret ${ENV_PREFIX}-${key} already exists"
done

# Add secret versions
echo -n "${APPLE_TEAM_ID}" | \
  gcloud secrets versions add ${ENV_PREFIX}-apple-team-id --data-file=- --project=${GCP_PROJECT}

echo -n "${APPLE_KEY_ID}" | \
  gcloud secrets versions add ${ENV_PREFIX}-apple-key-id --data-file=- --project=${GCP_PROJECT}

echo -n "${APPLE_SERVICE_ID}" | \
  gcloud secrets versions add ${ENV_PREFIX}-apple-service-id --data-file=- --project=${GCP_PROJECT}

gcloud secrets versions add ${ENV_PREFIX}-apple-private-key \
  --data-file="${APPLE_P8_FILE}" --project=${GCP_PROJECT}
```

### 1c. Create Facebook Secrets

```bash
# Create secrets
for key in facebook-app-id facebook-app-secret; do
  gcloud secrets create ${ENV_PREFIX}-${key} \
    --project=${GCP_PROJECT} \
    --replication-policy=automatic \
    2>/dev/null || echo "Secret ${ENV_PREFIX}-${key} already exists"
done

# Add secret versions
echo -n "${FACEBOOK_APP_ID}" | \
  gcloud secrets versions add ${ENV_PREFIX}-facebook-app-id --data-file=- --project=${GCP_PROJECT}

echo -n "${FACEBOOK_APP_SECRET}" | \
  gcloud secrets versions add ${ENV_PREFIX}-facebook-app-secret --data-file=- --project=${GCP_PROJECT}
```

### 1d. Verify Secrets Were Created

```bash
echo "=== Verifying ${ENV_PREFIX} secrets ==="
for key in apple-team-id apple-key-id apple-service-id apple-private-key facebook-app-id facebook-app-secret; do
  STATUS=$(gcloud secrets versions list ${ENV_PREFIX}-${key} \
    --project=${GCP_PROJECT} --format="value(state)" --limit=1 2>/dev/null)
  echo "${ENV_PREFIX}-${key}: ${STATUS:-NOT FOUND}"
done
```

Expected output (all should show `ENABLED`):
```
devtest-apple-team-id: ENABLED
devtest-apple-key-id: ENABLED
devtest-apple-service-id: ENABLED
devtest-apple-private-key: ENABLED
devtest-facebook-app-id: ENABLED
devtest-facebook-app-secret: ENABLED
```

---

## Phase 2: Apply External Secrets to Kubernetes

### 2a. Apply ExternalSecret Manifests

```bash
# DevTest
kubectl apply -f external-secrets/devtest/identity/externalsecret.yaml

# Prod
kubectl apply -f external-secrets/prod/identity/externalsecret.yaml
```

### 2b. Verify Sync Status

```bash
# DevTest
kubectl get externalsecrets -n identity-customer | grep -E "apple|facebook"

# Prod
kubectl get externalsecrets -n identity | grep -E "apple|facebook"
```

Expected: Both should show `SecretSynced` status.

```bash
# Verify the K8s secrets were created
# DevTest
kubectl get secrets -n identity-customer | grep -E "apple|facebook"

# Prod
kubectl get secrets -n identity | grep -E "apple|facebook"
```

---

## Phase 3: Deploy Helm Charts

Deploy via ArgoCD sync or manual Helm upgrade. The `admin-sso-job` runs as a PostSync hook.

```bash
# Verify admin-sso-job ran successfully
# DevTest
kubectl get jobs -n identity-customer | grep admin-sso
kubectl logs -n identity-customer job/<job-name> -c setup

# Prod
kubectl get jobs -n identity | grep admin-sso
kubectl logs -n identity job/<job-name> -c setup
```

Look for these lines in the logs:
```
[SUCCESS] Google IDP configured for tesserix-customer realm
[SUCCESS] Apple IDP configured for tesserix-customer realm
[SUCCESS] Facebook IDP configured for tesserix-customer realm
[SUCCESS] Auto-link flow configured for Google IDP
```

---

## Phase 4: Verification

### 4a. Verify IDPs Exist in Keycloak

```bash
# Get admin token (adjust namespace for env)
NAMESPACE="identity-customer"  # or "identity" for prod
TOKEN=$(kubectl exec -n ${NAMESPACE} deploy/keycloak -- \
  curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=<admin-password>&grant_type=password&client_id=admin-cli" \
  | jq -r '.access_token')

# List customer realm IDPs
kubectl exec -n ${NAMESPACE} deploy/keycloak -- \
  curl -s "http://localhost:8080/admin/realms/tesserix-customer/identity-provider/instances" \
  -H "Authorization: Bearer ${TOKEN}" | jq '.[].alias'
# Expected: "google", "apple", "facebook"

# List internal realm IDPs (run against identity-internal namespace)
kubectl exec -n identity-internal deploy/keycloak -- \
  curl -s "http://localhost:8080/admin/realms/tesserix-internal/identity-provider/instances" \
  -H "Authorization: Bearer ${TOKEN}" | jq '.[].alias'
# Expected: "google"
```

### 4b. Manual Login Tests

| Test | URL (DevTest) | Expected |
|---|---|---|
| Admin Google login | `admin-devtest.tesserix.app/login` > Click Google | Redirects to Google > back to admin dashboard |
| Storefront Google | `demo-store.tesserix.app/login` > Click Google | Redirects to Google > back to storefront |
| Storefront Apple | Same > Click Apple | Redirects to Apple Sign In > back to storefront |
| Storefront Facebook | Same > Click Facebook | Redirects to Facebook > back to storefront |

| Test | URL (Prod) | Expected |
|---|---|---|
| Admin Google login | `admin.mark8ly.com/login` > Click Google | Redirects to Google > back to admin dashboard |
| Storefront Google | `<store>.mark8ly.com/login` > Click Google | Redirects to Google > back to storefront |
| Storefront Apple | Same > Click Apple | Redirects to Apple Sign In > back to storefront |
| Storefront Facebook | Same > Click Facebook | Redirects to Facebook > back to storefront |

### 4c. Security Checks

- [ ] Verify `google_linked` / `apple_linked` / `facebook_linked` attributes set on users after social login
- [ ] Verify Auto Link flow links existing users by email (no duplicate accounts created)
- [ ] Verify `trustEmail: true` prevents Keycloak email verification prompts
- [ ] Verify Facebook app is in **Live** mode for prod (Development mode only allows test users)

---

## Troubleshooting

### ExternalSecret not syncing
```bash
kubectl describe externalsecret keycloak-apple-sso -n identity-customer
```
Common causes: GCP secret doesn't exist yet, IAM permissions missing on the service account.

### admin-sso-job failing
```bash
kubectl logs -n identity-customer job/<job-name> -c setup --tail=50
```
Common causes: Keycloak not ready (retry will handle), secret not mounted (ExternalSecret not synced).

### Social login redirects to error page
- Check the redirect URI is registered in the provider console
- Check the IDP alias matches what the frontend sends via `kc_idp_hint` (`google`, `apple`, `facebook`)
- Check Keycloak logs: `kubectl logs -n identity-customer deploy/keycloak --tail=100`

### Apple Sign In returns "invalid_client"
- Verify the `.p8` private key was uploaded correctly (not truncated)
- Verify `APPLE_SERVICE_ID` matches the Service ID identifier (not the App ID)
- Verify the return URL in Apple Developer matches exactly
