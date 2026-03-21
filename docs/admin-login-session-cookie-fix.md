# Admin Login Session Cookie Fix

**Date:** 2026-03-21
**Affected Service:** auth-bff, marketplace-admin
**Symptom:** Admin login at `{tenant}-admin.mark8ly.com` shows loading/flickering then logs out

---

## Root Cause

The auth-bff encrypted session cookie exceeded the browser's **4096-byte cookie size limit**.

### How it happened

The session cookie contains the full Keycloak JWT tokens (access token, ID token, refresh token) encrypted with AES-256-GCM. The encryption output used **hex encoding** which doubles every byte:

```
Session JSON (~3000 bytes)
→ AES-256-GCM encrypted (~3028 bytes)
→ Hex encoded (~6056 bytes)  ← EXCEEDS 4096 LIMIT
```

Browsers silently drop oversized cookies. After login, the `Set-Cookie` header was sent but the browser never stored it. Every subsequent `/auth/session` check returned `{authenticated: false}` because no cookie was present.

### Why it appeared as a flicker

1. User submits credentials → auth-bff returns `direct-login: success` (200 OK)
2. Frontend shows "Success" → redirects to `/` via `window.location.href`
3. Dashboard loads → AuthProvider calls `/auth/session`
4. No cookie → `{authenticated: false}` → redirect back to `/login`
5. User sees brief flash of dashboard then back to login

---

## Fix Applied

### 1. Auth-BFF: Compressed base64url encoding (primary fix)

**Repo:** `tesserix/auth-bff`
**Commit:** `b8a4087 fix: compress session cookie to fit browser 4KB limit`
**File:** `internal/crypto/aes.go`

Changed encryption output from hex to **gzip + base64url** with a `v2.` prefix:

```
Session JSON (~3000 bytes)
→ gzip compressed (~1200 bytes)
→ AES-256-GCM encrypted (~1228 bytes)
→ base64url encoded (~1640 bytes)  ← FITS in 4096 limit
```

**Backward compatibility:** `DecryptAESGCM()` detects the `v2.` prefix and routes to the new decoder. Old hex-format cookies are still readable during rolling deployments.

### 2. Marketplace-Admin: Fixed devtest defaults

**Repo:** `tesserix/marketplace-admin`
**Commit:** `3d535c6 fix: replace devtest references with prod defaults`

- `lib/config/secrets.ts`: Changed `GCP_SECRET_PREFIX` default from `'devtest'` to `'prod'`
- Updated all hardcoded GCS bucket defaults:
  - `marketplace-devtest-public-au` → `marketplace-prod-public-au`
  - `tesseracthub-devtest-assets` → `tesseracthub-prod-assets`

### 3. Helm Chart: Added GCP_SECRET_PREFIX to configmap

**Repo:** `tesserix/tesserix-k8s`
**Commit:** `6cc10f5 fix: add GCP_SECRET_PREFIX to marketplace-admin configmap`
**File:** `charts/apps/marketplace-admin/values-prod.yaml`

The `marketplace-common` configmap template for Next.js services does not use the `common.gcpSecretManagerEnv` helper (which auto-sets `GCP_SECRET_PREFIX` from `gcp.secretManager.secretPrefix`). Added `GCP_SECRET_PREFIX: "prod"` explicitly to the `env` section.

---

## Deployment Procedure

### Order matters — deploy auth-bff first

The auth-bff creates the session cookies. If marketplace-admin deploys first, it would still receive old-format cookies from the old auth-bff (which are too large).

```bash
# 1. Deploy auth-bff
gh repo edit tesserix/auth-bff --visibility public --accept-visibility-change-consequences
cd auth-bff && git push origin main
gh run list --repo tesserix/auth-bff --limit 3
# Wait for green...
gh repo edit tesserix/auth-bff --visibility private --accept-visibility-change-consequences

# Auth-bff is a Helm Deployment (not Knative) — CI patches ksvc in wrong namespace.
# Restart manually to pick up new image:
kubectl rollout restart deployment/auth-bff -n marketplace
kubectl rollout status deployment/auth-bff -n marketplace

# 2. Deploy marketplace-admin (Knative — CI handles restart)
gh repo edit tesserix/marketplace-admin --visibility public --accept-visibility-change-consequences
cd marketplace-admin && git push origin main
gh run list --repo tesserix/marketplace-admin --limit 3
# Wait for green...
gh repo edit tesserix/marketplace-admin --visibility private --accept-visibility-change-consequences

# 3. Push tesserix-k8s (ArgoCD auto-syncs configmap)
cd tesserix-k8s && git push origin main
```

---

## How to Debug Login Issues

### Check auth-bff logs for the login flow

```bash
kubectl logs -n marketplace -l app.kubernetes.io/name=auth-bff -c auth-bff --tail=100 \
  | grep -v health | grep -E "session|login|error" -i
```

**Healthy login flow:**
```
POST /auth/direct/admin/login → 200, ~500-1000ms  (direct-login: success)
GET  /auth/session             → 200, 0ms          (returns authenticated: true)
POST /internal/session-exchange → 200               (admin server gets tokens)
```

**Broken login (cookie too large):**
```
POST /auth/direct/admin/login → 200, ~500ms  (success)
GET  /auth/session             → 200, 0ms    (authenticated: false — no cookie!)
```

### Check cookie size in browser

Open DevTools → Application → Cookies → `{tenant}-admin.mark8ly.com`

Look for `bff_mk_admin_session`:
- **v2 format:** Starts with `v2.` — compressed, should be ~1500-2000 bytes
- **Legacy hex format:** Contains `:` separators — hex encoded, likely >4096 bytes (broken)

### Check marketplace-admin for CSRF/secret errors

```bash
kubectl logs -n marketplace -l app=marketplace-admin -c app --tail=50 \
  | grep -E "csrf|secret|ERROR" -i
```

If you see `devtest-csrf-secret NOT_FOUND`, the `GCP_SECRET_PREFIX` is not set to `prod`.

---

## Related Configuration

| Config | Location | Value |
|--------|----------|-------|
| Session cookie name | `auth-bff/products.yaml` → admin app | `bff_mk_admin_session` |
| Cookie domain | Computed by `GetCookieDomain()` | `.mark8ly.com` |
| Encryption key | GCP Secret Manager | `prod-encryption-key` |
| GCP_SECRET_PREFIX | marketplace-admin configmap | `prod` |
| OAuth client ID (admin) | `auth-bff/products.yaml` | `677812215720-a8msqv3sgc67fan63fbo2puva6c6u9jm` |
| GIP tenant (admin) | `auth-bff/products.yaml` | `MP-Internal-uidfu` |
