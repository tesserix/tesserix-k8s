# Observability UI — Google OAuth setup

One manual step. The OAuth client cannot be created from the CLI, so
`prod-obs-api-google-client-id` and `prod-obs-api-google-client-secret` do not
exist yet and the `obs-api-secrets` ExternalSecret will stay unsynced until they
do. That is deliberate: a placeholder credential would let `obs-api` start and
then fail sign-in in a way that looks like a bug rather than a missing step.

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

## 2. Store the credentials

```bash
PROJECT=tesseracthub-480811

printf '%s' '<CLIENT_ID>' | gcloud secrets create prod-obs-api-google-client-id \
  --project="$PROJECT" --replication-policy=automatic --data-file=-

printf '%s' '<CLIENT_SECRET>' | gcloud secrets create prod-obs-api-google-client-secret \
  --project="$PROJECT" --replication-policy=automatic --data-file=-
```

`printf` rather than `echo`: `echo` appends a newline, and a trailing newline in
a credential is a genuinely painful class of bug — this exact problem broke
`prod-resend-api-key` v1.

## 3. Force a resync

ExternalSecrets refresh hourly. To pick the values up immediately:

```bash
kubectl delete secret obs-api-secrets -n observability
```

The operator recreates it within seconds.

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
