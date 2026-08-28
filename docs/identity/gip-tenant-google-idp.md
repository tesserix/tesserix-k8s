# GIP Tenant Google IdP — which OAuth client to use

Status: **Code-of-record for new product tenants on tesseracthub-480811**.

## TL;DR

When enabling the Google sign-in provider on a new GIP tenant via the
Identity Toolkit Admin API, set:

```
clientId     = 849928263410-3n4fva16mmmmk9qgkk1d6fr36ctcfmpg.apps.googleusercontent.com
clientSecret = (read from prod-firebase-web-oauth-client-secret via Secret Manager
                — or pull live from the project-level config:
                GET /admin/v2/projects/tesseracthub-480811/defaultSupportedIdpConfigs/google.com)
```

Do NOT use `849928263410-5djgu3n40c5tpr86votuptkitqveegor...`. That client is
mark8ly's **server-side** OAuth client; its Authorized Redirect URIs only
include `https://mark8ly.com/...` callbacks, not the Firebase Auth handler at
`https://tesseracthub-480811.firebaseapp.com/__/auth/handler`. Using it from
a `signInWithPopup` web flow produces `Error 400: redirect_uri_mismatch`.

## Why several OAuth clients?

The tesseracthub-480811 project now holds **more than two** Google OAuth Web
Clients. Only the first two below are GIP's; the rest belong to Zitadel and must
never be bound to a GIP tenant:

| Client suffix | Created by | Used for | Auth redirect URIs |
|---|---|---|---|
| `-5djgu3n40c5...` | manual Console (mark8ly setup) | mark8ly server-side OAuth dance (mark8ly-auth-bff Go service) | `https://mark8ly.com/oauth/callback`, etc. |
| `-3n4fva16mm...` | Firebase Console auto-created when Google sign-in was first enabled at project level | Firebase Web SDK `signInWithPopup` / multi-tenant flows | `https://tesseracthub-480811.firebaseapp.com/__/auth/handler` |
| `-ctrdo7o0sj68...` | **Zitadel** — TESSERIX org IdP `386381087862948767` | Google sign-in at `auth.tesserix.app`. **Not GIP.** | Zitadel login callbacks |
| `-eq63i2v34j61...` | **Zitadel** — ZITADEL org IdP `386336249998213772` | Orphaned: the IdP is ACTIVE but referenced by no login policy. **Not GIP.** | Zitadel login callbacks |

The two systems are independent and stay that way through the migration: mark8ly,
Fanzone, HomeChef and Blog authenticate through GIP with the Firebase client;
console, aregistry, mcp, agentgateway and atlantis authenticate through Zitadel
with its own. Binding a Zitadel client to a GIP tenant — or vice versa — makes
secret rotation a cross-system outage. Consolidating the two Zitadel clients onto
one instance-level connector is tracked in #676.

Google does **not** expose a public API for managing the Authorized
JavaScript Origins / Authorized Redirect URIs of a Web OAuth client.
Those settings live in Console only. The choice of WHICH client to bind
to a GIP tenant is API-controlled and lives in this repo.

## Onboarding a new product (Helm + script)

`scripts/identity/enable-tenant-google-idp.py` is the canonical
implementation. Given a tenant ID it:

1. Reads `defaultSupportedIdpConfigs/google.com` from the project level.
2. Writes that `{clientId, clientSecret, enabled: true}` onto the tenant's
   own `defaultSupportedIdpConfigs/google.com` (creates or patches).

Re-run is a no-op. Bundle it with the per-product tenant-creation script
in `scripts/identity/`.

## Verifying

```bash
# Authoritative answer per tenant
.fbenv/bin/python -c "
import requests, subprocess
tok = subprocess.check_output(['gcloud','auth','print-access-token']).decode().strip()
for t in ['Fanzone-ut25f','HomeChef-gufzu','Blog-znj8b']:
  r = requests.get(
    f'https://identitytoolkit.googleapis.com/admin/v2/projects/tesseracthub-480811/tenants/{t}/defaultSupportedIdpConfigs/google.com',
    headers={'Authorization': f'Bearer {tok}', 'x-goog-user-project':'tesseracthub-480811'},
  ).json()
  print(t, '->', r.get('clientId',''))
"
# Expected output for each: ...-3n4fva16mmmmk9qgkk1d6fr36ctcfmpg.apps.googleusercontent.com
```

If any tenant shows the `-5djgu3n40c5...` (mark8ly) clientId, customer
sign-in from that product domain will fail with `redirect_uri_mismatch`
the moment a user clicks "Continue with Google" — re-run the enable script.
