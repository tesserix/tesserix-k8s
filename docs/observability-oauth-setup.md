# Observability UI — Google OAuth setup

The observability application uses a dedicated Google OAuth client. Its existing
credentials are migrated without rotation; create a client only for a new
installation. Store application credentials in OpenBao, never GCP Secret Manager.

## 1. Create the OAuth client

In [Google Cloud Console → APIs & Services → Credentials](https://console.cloud.google.com/apis/credentials?project=tesseracthub-480811):

1. **Create Credentials → OAuth client ID**
2. Application type: **Web application**
3. Name: `Tesserix Observability`
4. **Authorised redirect URIs** — both entries:
   - `https://observability.tesserix.app/auth/callback`
   - `http://localhost:8080/auth/callback` (local development)

The redirect URI must match exactly what `obs-api` sends. That value is derived
from `OBS_API_PUBLIC_URL` plus `/auth/callback`, so if you change the domain you
must change both.

Use a **dedicated** client rather than the existing shared
`prod-google-client-id`. A dedicated client keeps this redirect-URI list scoped
to one app, so a change here cannot break another product's login.

## 2. Store credentials in OpenBao

Use a short-lived token scoped to create/read only these two paths:

- `kv/data/observability/app/observability-google-client-id`
- `kv/data/observability/app/observability-google-client-secret`

Authenticate to the approved OpenBao endpoint with a protected token. Supply the
provider-exported values through protected local files, preserving their exact
bytes. Keep the files outside the repository and remove them after verification.
Create-only CAS refuses to replace an existing credential:

```bash
bao kv put -cas=0 kv/observability/app/observability-google-client-id \
  value=- < /secure/path/client-id
bao kv put -cas=0 kv/observability/app/observability-google-client-secret \
  value=- < /secure/path/client-secret
bao token revoke -self
```

For an existing installation, validate equality with its reviewed inventory.
Credential rotation requires a separate approved change, a scoped update token
and CAS against the current version; never bypass a create-only conflict.

The session signing key and GitHub App ID, installation ID and PEM private key
also belong under `observability/app/observability-*`. The exact six destinations
are recorded in `scripts/product-secret-targets.json`. Preserve the GitHub key's
PEM line breaks and its existing file mount in the application.

## 3. Verify synchronization and sign-in

`obs-api-secrets` reads through the namespace-bound
`openbao-observability-production` SecretStore every five minutes. Wait for its
Ready condition and a fresh status refresh time; do not delete the Kubernetes
Secret to force refresh. Verify `/healthz`, `/readyz`, Google client authentication
and an authorized sign-in. For a new value or approved rotation, roll the app
through its owning GitOps configuration after synchronization so environment
variables reload. An unchanged migration does not require a restart.

## Who can sign in

The allowlist lives in `charts/apps/obs-api/values.yaml` under `allowedEmails`
and is passed to the container as `ALLOWED_EMAILS`:

- `samyak.rout@gmail.com`
- `unidevidp@gmail.com`
- `mahesh.sangawar@gmail.com`

These are personal Gmail accounts, so there is no domain to trust — this list is
the entire authorisation model. Two properties are enforced in code:

- Google must report the address as **verified**. An unverified Google address
  can be set to anything at account creation, so trusting it would let anyone
  claim an allowlisted address.
- An empty allowlist is a **startup failure**, not a permissive default.
  Otherwise anyone with a Google account could sign in.

To add someone: edit `allowedEmails`, commit, let ArgoCD sync. No separate
identity record is involved.
