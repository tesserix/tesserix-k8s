# Customer Keycloak Social Login — Fix Reference

> **Read this whenever working on customer-side login, signup, social login
> (Google/Facebook), identity provider config, or first-broker-login flow
> issues for any product whose customer portal authenticates against the
> customer Keycloak instance (`identity-customer` namespace, `homechef` realm
> for HomeChef / fe3dr.com).**

This document captures the bugs that broke Google sign-in on fe3dr.com and
how each is now resolved. The same patterns apply to adding Facebook or any
other IdP to the same realm. For **admin-side** (internal Keycloak) issues, see
[`docs/internal-keycloak-admin-bff-fix.md`](internal-keycloak-admin-bff-fix.md).

---

## TL;DR architecture (the working state)

```
Browser ── https://fe3dr.com/bff/auth/login?kc_idp_hint=google ──▶ Istio
                                                                    │
                                                        /bff/* rewritten to /
                                                        (no x-auth-context)
                                                                    ▼
                                                     homechef-auth-bff (Knative)
                                                     │  KEYCLOAK_CUSTOMER_URL = https://identity.fe3dr.com
                                                     │  KEYCLOAK_CUSTOMER_INTERNAL_URL = http://keycloak.identity-customer:8080
                                                     │
                                                     │ Redirect browser → Keycloak authorize URL
                                                     │ redirect_uri = https://fe3dr.com/auth/callback
                                                     ▼
                                                     Keycloak (identity-customer namespace)
                                                     │  Realm: homechef
                                                     │  Client: homechef-bff
                                                     │  Google IdP: alias=google
                                                     │  firstBrokerLoginFlowAlias: auto-link-by-email
                                                     ▼
                                                     Browser → Google OAuth → callback →
                                                     Keycloak auto-links by email →
                                                     redirect to BFF callback →
                                                     BFF creates session → fe3dr.com home
```

Required pieces:

1. The `google` (or `facebook`) **identity provider must exist** in the live
   homechef realm with real credentials (not placeholders), `trustEmail: true`,
   and `firstBrokerLoginFlowAlias: "auto-link-by-email"`.
2. The **`auto-link-by-email` authentication flow** must have **both**
   `idp-create-user-if-unique` AND `idp-auto-link` executions, **both** set to
   `ALTERNATIVE`. Missing the `idp-auto-link` execution causes Keycloak to
   fall back to the default flow which prompts for a password.
3. The web frontend **must NOT hardcode** `VITE_BFF_URL` to
   `https://identity.fe3dr.com` — it must use same-origin
   `${window.location.origin}/bff`. Otherwise the BFF constructs
   `redirect_uri=https://identity.fe3dr.com/auth/callback` which is not in
   the client's allowed redirect URIs.
4. The **Google OAuth redirect URI** must be in the GCP Console:
   `https://identity.fe3dr.com/realms/homechef/broker/google/endpoint`

---

## The bugs we hit

### 1. `VITE_BFF_URL` hardcoded to Keycloak host in FOUR files

**Symptom:** Keycloak renders "Invalid parameter: redirect_uri".

**Cause:** the web frontend had `import.meta.env.VITE_BFF_URL || 'https://identity.fe3dr.com'`
in four separate files. The browser navigated to `identity.fe3dr.com/auth/login`
instead of `fe3dr.com/bff/auth/login`. The BFF then derived
`redirect_uri=https://identity.fe3dr.com/auth/callback` from the request Host,
and Keycloak rejected it because the `homechef-bff` client only allows
`https://fe3dr.com/bff/callback`.

**Files fixed** (all in `Home-Chef-App/apps/web/src/`):
- `features/auth/services/auth-service.ts:3`
- `app/providers/AuthProvider.tsx:16` — **the one driving the login click**
- `features/customer/pages/ProfilePage.tsx:1074`
- `shared/services/api-client.ts:4`

Also fixed in:
- `apps/web/Dockerfile:36` (`ARG VITE_BFF_URL=` → empty instead of Keycloak host)
- `.github/workflows/homechef-web-build.yml:98` (CI default removed)

All now use the same-origin pattern:
```typescript
const BFF_URL = (() => {
  const env = import.meta.env.VITE_BFF_URL;
  if (env) return env;
  if (typeof window !== 'undefined' && window.location.hostname !== 'localhost') {
    return `${window.location.origin}/bff`;
  }
  return '/bff';
})();
```

### 2. No Google IdP in the homechef realm

**Symptom:** clicking "Continue with Google" shows the email/password form
instead of redirecting to Google.

**Cause:** the homechef realm had zero `identityProviders`. The web frontend
sends `kc_idp_hint=google` but Keycloak ignored it (no IdP with alias `google`
exists) and showed the default login form.

**Fix:** the idempotent bootstrap job
`charts/thirdparty/identity-customer/templates/homechef-realm-bootstrap-job.yaml`
creates the google IdP via the Keycloak admin API with real credentials from the
`keycloak-google-sso` K8s secret. The IdP config uses `trustEmail: true` and
`firstBrokerLoginFlowAlias: "auto-link-by-email"`.

The realm-configmap.yaml also has the IdP definition (with `${GOOGLE_CLIENT_ID}`
placeholders) for fresh imports, but the customer realm-import-job does NOT
substitute these placeholders — so the bootstrap job is the only path that
produces a working IdP on existing realms.

### 3. `auto-link-by-email` flow missing `idp-auto-link` execution

**Symptom:** after completing Google sign-in, Keycloak shows "We are sorry...
Invalid username or password" on the first-broker-login page, instead of
auto-linking the Google identity to the existing user.

**Cause:** the realm-configmap.yaml defines the `auto-link-by-email` flow with
two executions (`idp-create-user-if-unique` + `idp-auto-link`). But the
customer realm-import-job uses `partialImport?ifResourceExists=SKIP` which
imported the flow *without* its executions properly. The flow existed with only
`idp-create-user-if-unique` set to `DISABLED` and no `idp-auto-link` at all.

Without `idp-auto-link`, Keycloak can't auto-link the Google identity to the
existing user record. It falls back to the built-in first-broker-login flow
which prompts the user to "prove" ownership of their existing account by
entering a password — but the user only has a Google account, no password.

**Fix:** the bootstrap job now checks the flow's executions even when the flow
already exists, and adds any missing executions + sets requirements to
ALTERNATIVE. This makes the job truly idempotent against partial-import damage.

### 4. Realm-import-job doesn't substitute Google credentials

**Symptom:** even after adding the IdP to realm-configmap.yaml, the live
Keycloak has literal `${GOOGLE_CLIENT_ID}` strings instead of real credentials.

**Cause:** the customer realm-import-job's env section has no `GOOGLE_CLIENT_ID`
or `GOOGLE_CLIENT_SECRET` environment variables. The placeholders in the realm
JSON are never substituted. (The fanzone realm has the same issue.)

**Fix:** the bootstrap job reads the real credentials from the `keycloak-google-sso`
K8s secret (synced from GCP Secret Manager: `prod-google-client-id`,
`prod-google-client-secret`) and writes them directly to the IdP via PUT.
Credential rotation is picked up automatically on the next bootstrap run.

---

## How to add Facebook (or another IdP)

Mirror the Google pattern:

1. **GCP Secret Manager** — ensure `prod-facebook-app-id` and
   `prod-facebook-app-secret` exist (they do — verified 2026-04-10).
2. **External Secrets** — verify `keycloak-facebook-sso` is synced to
   `identity-customer` namespace (it is, in
   `external-secrets/prod/identity-customer/externalsecret.yaml`).
3. **Realm configmap** — add a `facebook` entry to `identityProviders[]` in the
   homechef realm JSON, plus `identityProviderMappers[]`.
4. **Bootstrap job** — extend to upsert the `facebook` IdP and its mappers,
   reading from the `keycloak-facebook-sso` K8s secret.
5. **Meta for Developers Console** — add the redirect URI:
   `https://identity.fe3dr.com/realms/homechef/broker/facebook/endpoint`
6. Push, sync, test.

## How to add a new customer user

No action needed — customer signup is self-service via the Keycloak hosted
registration form (`registrationAllowed: true`). New users get the `customer`
default role. Social login auto-provisions users via `idp-create-user-if-unique`.

## Account linking semantics

With `auto-link-by-email` + `trustEmail: true` + `duplicateEmailsAllowed: false`:

| Scenario | What happens |
|----------|-------------|
| **New email, Google sign-in** | Keycloak creates a new `homechef` realm user with profile from Google, `emailVerified=true`, default role `customer` |
| **Existing email/password user, first Google sign-in** | `idp-auto-link` links the Google identity to the existing user record — no password prompt, no manual confirmation |
| **Same user, later adds Facebook** | Same linking — `idp-auto-link` matches by verified email |
| **Same user, logs in with email/password** | Works as before; Google/Facebook links remain attached |
| **Duplicate email attempted** | Blocked by `duplicateEmailsAllowed: false`; Keycloak links instead of creating a second record |

## Troubleshooting checklist

```bash
export KUBECONFIG=~/.kube/gke-prod
BFF_POD=$(kubectl get pod -n homechef -l app.kubernetes.io/name=homechef-auth-bff \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```

1. **Does the Google IdP exist in the realm?**
   ```bash
   # From BFF pod (fresh token per request due to short-lived admin tokens):
   kubectl exec -n homechef "$BFF_POD" -c user-container -- node -e '...'
   # Check: /admin/realms/homechef/identity-provider/instances/google → 200
   # Verify: firstBrokerLoginFlowAlias === "auto-link-by-email"
   # Verify: trustEmail === true
   ```

2. **Does the auto-link-by-email flow have BOTH executions?**
   ```bash
   # GET /admin/realms/homechef/authentication/flows/auto-link-by-email/executions
   # Must show: idp-create-user-if-unique:ALTERNATIVE, idp-auto-link:ALTERNATIVE
   # If only one or DISABLED → add/update via POST/PUT (see bootstrap job)
   ```

3. **Does the JS bundle use same-origin BFF_URL?**
   ```bash
   kubectl exec -n homechef "$WEB_POD" -c user-container -- \
     grep "identity.fe3dr.com" /usr/share/nginx/html/assets/auth-service*.js
   # Should return NO matches. If it does, the image needs rebuilding.
   ```

4. **Is the Google redirect URI in GCP Console?**
   ```
   https://identity.fe3dr.com/realms/homechef/broker/google/endpoint
   ```

## What NOT to do

- **Do not** set `VITE_BFF_URL` to `https://identity.fe3dr.com` anywhere. Not
  in `.env`, not in the Dockerfile, not in CI variables. The correct production
  value is `${window.location.origin}/bff` (same-origin, computed at runtime).
- **Do not** rely on the customer realm-import-job to substitute
  `${GOOGLE_CLIENT_ID}` placeholders. It has no env vars for Google credentials.
  Use the bootstrap job which reads from K8s secrets directly.
- **Do not** assume `partialImport?ifResourceExists=SKIP` creates complete
  authentication flows. It may create the flow object without its executions.
  Always verify executions after import.
- **Do not** use `mark8ly-auth-bff` as a reference for customer-side BFF config.
  The correct reference is `devai-auth-bff` (same `ghcr.io/tesseract-nexus/
  global-services/auth-bff` image).

## Relevant files

| Layer | File |
|-------|------|
| Realm definition (fresh imports) | `charts/thirdparty/identity-customer/templates/realm-configmap.yaml` (homechef section) |
| Idempotent realm patcher | `charts/thirdparty/identity-customer/templates/homechef-realm-bootstrap-job.yaml` |
| One-shot realm import | `charts/thirdparty/identity-customer/templates/realm-import-job.yaml` |
| Standalone ESO | `external-secrets/prod/identity-customer/externalsecret.yaml` |
| ArgoCD app | `argocd/prod/infrastructure/identity-customer.yaml` |
| BFF chart (customer side) | `charts/apps/homechef-auth-bff/values-prod.yaml` |
| Web app auth-service | `Home-Chef-App/apps/web/src/features/auth/services/auth-service.ts` |
| Web app AuthProvider | `Home-Chef-App/apps/web/src/app/providers/AuthProvider.tsx` |
| Web app api-client | `Home-Chef-App/apps/web/src/shared/services/api-client.ts` |
| Web app Dockerfile | `Home-Chef-App/apps/web/Dockerfile` |
| Web CI workflow | `Home-Chef-App/.github/workflows/homechef-web-build.yml` |
| Istio routing (fe3dr.com) | `manifests/homechef-istio/virtualservice.yaml` (fe3dr.com + identity.fe3dr.com blocks) |
| Reference: fanzone Google IdP | `charts/thirdparty/identity-customer/templates/realm-configmap.yaml` (fanzone section, lines 487-534) |
