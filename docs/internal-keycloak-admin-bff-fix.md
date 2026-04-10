# Internal Keycloak Admin BFF — Fix Reference

> **Read this whenever working on admin login, SSO, or identity-provider issues
> for any product whose admin portal authenticates against the internal
> Keycloak instance (`identity-internal` namespace, `tesserix-internal` realm
> by default).**

This document captures the four distinct bugs that broke
`https://admin.fe3dr.com/login` and how each is now resolved. The same patterns
apply to any future product that wires its admin portal through
`homechef-auth-bff` / `devai-auth-bff` / similar Backend-for-Frontend services
against the internal Keycloak.

---

## TL;DR architecture (the working state)

```
Browser ── https://admin.fe3dr.com/bff/auth/login ──▶ Istio
                                                      │
                                                      ▼ /bff/* rewritten to /
                                                      │ x-auth-context: admin
                                                      ▼
                                       homechef-auth-bff (Knative svc)
                                       │
                                       │ Discovery, /token, /userinfo
                                       │ via in-cluster URL
                                       ▼
                                       keycloak.identity-internal.svc:8080
                                       │ Realm: tesserix-internal
                                       │ Client: homechef-admin-bff
                                       │ frontendUrl attribute pinned
                                       │ realm-roles protocolMapper enabled
                                       ▼
                                       Browser redirects → public URL
                                       (https://internal-identity.fe3dr.com)
                                       Token includes roles claim
                                       BFF sees roles=[admin] → grants access
```

Required pieces, all of them:

1. The OIDC client (`<product>-admin-bff`) **must exist in the live realm** with
   a client secret that matches the BFF's env var.
2. The realm **must have `attributes.frontendUrl`** set to the public URL so
   discovery responses are stable regardless of which hostname the BFF reaches
   Keycloak through.
3. The BFF **must use the in-cluster Keycloak URL** for back-channel calls so
   the `Authorization` header is not stripped by Cloudflare.
4. The OIDC client **must have the `realm-roles` protocol mapper**, the realm
   **must define an `admin` role**, and **each allowed admin user must be
   pre-created with `realmRoles: ["admin"]`**.

Miss any one of these and login bounces back to `/login?error=token_exchange_failed`.

---

## The four bugs

### 1. The OIDC client only exists in Git, not in live Keycloak

**Symptom:** browser lands on
`https://internal-identity.fe3dr.com/realms/tesserix-internal/protocol/openid-connect/auth?...`
and Keycloak renders **"Client not found"**.

**Cause:** `charts/thirdparty/identity-internal/templates/realm-import-job.yaml`
is one-shot — it checks if the realm exists and exits 0 if so. Any client added
to `realm-configmap.yaml` *after* the original import never reaches the live
realm.

**Fix:** the idempotent post-install/upgrade hook
`charts/thirdparty/identity-internal/templates/homechef-clients-bootstrap-job.yaml`
upserts the client via the Keycloak admin API. The same pattern can be reused
for other admin BFF clients in the same realm.

**Required external secret:** the Helm-templated and standalone ExternalSecrets
both need a key for the client secret, mapped from a GCP Secret Manager entry
shared with the BFF chart so Keycloak and the BFF agree on the value:

- Standalone: `external-secrets/prod/identity-internal/externalsecret.yaml`
- Helm template: `charts/thirdparty/identity-internal/templates/client-secrets-external-secret.yaml`
- BFF side: `charts/apps/homechef-auth-bff/templates/externalsecret.yaml` (env
  var `KEYCLOAK_INTERNAL_CLIENT_SECRET`)

GCP secret name convention: `prod-<product>-internal-keycloak-client-secret`
(e.g. `prod-homechef-internal-keycloak-client-secret`).

### 2. `--hostname-strict=false` returns dynamic discovery URLs

**Symptom:** after starting the OIDC code grant the browser is redirected to
`http://keycloak.identity-internal.svc.cluster.local/...` and the user gets
`DNS_PROBE_FINISHED_NXDOMAIN`. **Or** the BFF logs
`outgoing request timed out after 3500ms` because it received a discovery
document full of in-cluster URLs and is trying to reach them via the public
gateway.

**Cause:** the internal Keycloak runs with `--hostname-strict=false` so the
issuer / authorization / token / userinfo URLs in
`.well-known/openid-configuration` are derived from the request `Host` header.
A request via the in-cluster service yields cluster-local URLs; a request via
the public host yields public URLs. The BFF caches whatever it discovered
first.

**Fix:** set `attributes.frontendUrl` on the realm to the public URL. With
that attribute, Keycloak returns the public URL in discovery responses
**regardless of how it was reached**, while still letting other realms on the
same Keycloak (devai, marketplace, fanzone) keep their own dynamic hostnames.

This is enforced two ways:
- `realm-configmap.yaml` declares `attributes.frontendUrl` for fresh imports.
- `homechef-clients-bootstrap-job.yaml` performs an idempotent
  `PUT /admin/realms/<realm>` to set the attribute on existing realms.

> **Do NOT set `--hostname` on the Keycloak StatefulSet** — that would override
> the hostname for *every* realm and break devai / marketplace / fanzone which
> serve `tesserix-internal` under different hostnames.

### 3. Cloudflare strips the `Authorization` header on the userinfo path

**Symptom:** Keycloak event log shows `LOGIN` and `CODE_TO_TOKEN` succeeding
for the user, but the BFF logs `Token exchange failed: invalid_token` with the
response body `Jwt issuer is not configured`. Reproduce manually:

```bash
# From inside the BFF pod (replace token):
curl -i https://internal-identity.fe3dr.com/realms/tesserix-internal/protocol/openid-connect/userinfo \
  -H "Authorization: Bearer $TOKEN"
# → HTTP/1.1 401, body: "Jwt issuer is not configured"

curl -i http://keycloak.identity-internal.svc.cluster.local:8080/realms/tesserix-internal/protocol/openid-connect/userinfo \
  -H "Authorization: Bearer $TOKEN"
# → HTTP/1.1 200, valid user info
```

**Cause:** the Cloudflare → Cloudflare Tunnel → Istio Gateway path strips the
`Authorization` header from `GET /protocol/openid-connect/userinfo` requests.
The token endpoint, the introspection endpoint, and `POST /userinfo` all work
through the public path because they accept the token in the request body.
**Only the `GET /userinfo` flow that openid-client uses is affected.**

**Fix:** the BFF must use the in-cluster service URL for back-channel calls.
Set `keycloak.internal.internalUrl` in the BFF chart values to the cluster
service URL — the deployment template gates `KEYCLOAK_INTERNAL_INTERNAL_URL`
on this being non-empty:

```yaml
# charts/apps/homechef-auth-bff/values-prod.yaml
keycloak:
  internal:
    url: "https://internal-identity.fe3dr.com"
    internalUrl: "http://keycloak.identity-internal.svc.cluster.local:8080"
    realm: "tesserix-internal"
```

This is **safe only because** bug 2 is also fixed (`frontendUrl` is set), which
means in-cluster discovery now returns public URLs everywhere.

### 4. The BFF requires a `roles` claim with `admin`, not a tenant lookup

**Symptom:** after the userinfo call finally succeeds, the BFF logs
`module: tenant-service-client, msg: Error getting user tenants` and redirects
back to `/login`.

**Cause:** the shared `ghcr.io/tesseract-nexus/global-services/auth-bff` image
makes its access decision from the user's `roles` claim. If the claim is empty
or missing, the BFF falls back to a `tenant-service` lookup. HomeChef has no
tenant-service deployed, the call fails, and the BFF redirects to login. The
`tesserix-internal` realm already defines an `admin` role but:

- The `homechef-admin-bff` client had no `realm-roles` protocol mapper, so the
  token never carried a `roles` claim.
- No allowed admin users were pre-created with the `admin` role assigned, so
  the Google IdP auto-created users with only the default `staff` role.

**Fix (mirrors how `devai-sre-bff` works):**
- Add a `realm-roles` protocol mapper to the OIDC client (id_token,
  access_token, **and** userinfo).
- Pre-create each allowed admin user in the realm with
  `realmRoles: ["admin"]`. Keycloak's first-broker-login flow will link the
  Google identity to the existing user record by email on first sign-in.

Both are persisted in `realm-configmap.yaml` and applied to existing realms
by `homechef-clients-bootstrap-job.yaml` via the admin API. The bootstrap job
is idempotent — re-runs are no-ops.

---

## How to add a new admin user

Edit `charts/thirdparty/identity-internal/templates/realm-configmap.yaml` and
the bootstrap job, then push. ArgoCD will sync and the post-upgrade hook will
upsert the user via the admin API.

1. **Realm config** — add to the `users` array of the realm JSON:
   ```json
   {
     "username": "new.admin@example.com",
     "email": "new.admin@example.com",
     "emailVerified": true,
     "enabled": true,
     "firstName": "New",
     "lastName": "Admin",
     "realmRoles": ["admin"]
   }
   ```

2. **Bootstrap job** — add the email to the `ADMIN_EMAILS` shell variable in
   `charts/thirdparty/identity-internal/templates/homechef-clients-bootstrap-job.yaml`:
   ```bash
   ADMIN_EMAILS="samyak.rout@gmail.com mahesh.sangawar@gmail.com unidevidp@gmail.com new.admin@example.com"
   ```

3. **Google OAuth allowlist** — if Google's OAuth client is in test mode, add
   the email to the test users list in GCP Console → APIs & Services → OAuth
   consent screen.

4. Commit, push, ArgoCD will run the bootstrap job on next sync.

## How to wire up a new admin BFF (e.g. for a new product)

Mirror the homechef setup:

1. **OIDC client** — add a `<product>-admin-bff` confidential client to
   `realm-configmap.yaml` with the `realm-roles` protocol mapper. Set
   `redirectUris` to `https://admin.<product>.com/bff/callback` etc.

2. **GCP secret** — create
   `prod-<product>-internal-keycloak-client-secret` in GCP Secret Manager.

3. **External secrets** — add a key mapping in
   `external-secrets/prod/identity-internal/externalsecret.yaml` and the same
   templated mapping in
   `charts/thirdparty/identity-internal/templates/client-secrets-external-secret.yaml`,
   with the value name in `argocd/prod/infrastructure/identity-internal.yaml`
   under `keycloak.externalSecrets.secrets`.

4. **Bootstrap job** — duplicate `homechef-clients-bootstrap-job.yaml` (or
   extend it with another client block) so the new client is upserted on
   existing realms. Use a unique `helm.sh/hook-weight` per job (current jobs
   use weights 5 and 6, devai uses 10).

5. **BFF chart** — set `keycloak.internal.internalUrl` to the in-cluster URL,
   `keycloak.internal.url` to the public URL, and verify the BFF's
   `externalsecret.yaml` pulls the same GCP secret as the Keycloak side.

6. **Istio routing** — add the `admin.<product>.com` host to a VirtualService
   with `/bff/*` rewriting to `/` and the
   `x-auth-context: admin` header injected, routed to the auth-bff service.

## Troubleshooting checklist

When admin login fails, run through these in order. The diagnostic snippets
below all run inside the BFF pod to bypass network surprises.

```bash
export KUBECONFIG=~/.kube/gke-prod
BFF_POD=$(kubectl get pod -n homechef -l app.kubernetes.io/name=homechef-auth-bff \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```

1. **Is the OIDC client in the live realm?** (Bug 1)
   ```bash
   kubectl exec -n homechef "$BFF_POD" -c user-container -- node -e '
     const https=require("https"); const qs=require("querystring");
     const d=qs.stringify({grant_type:"client_credentials",client_id:"homechef-admin-bff",client_secret:process.env.KEYCLOAK_INTERNAL_CLIENT_SECRET});
     const r=https.request({hostname:"internal-identity.fe3dr.com",path:"/realms/tesserix-internal/protocol/openid-connect/token",method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded","Content-Length":Buffer.byteLength(d)}},x=>{let b="";x.on("data",c=>b+=c);x.on("end",()=>console.log("status",x.statusCode,b.slice(0,200)))});r.write(d);r.end();'
   ```
   200 → client exists. 401 / "Client not found" → Bug 1, run the bootstrap job.

2. **Does discovery return public URLs via the in-cluster path?** (Bug 2)
   ```bash
   kubectl exec -n homechef "$BFF_POD" -c user-container -- node -e '
     require("http").get("http://keycloak.identity-internal.svc.cluster.local:8080/realms/tesserix-internal/.well-known/openid-configuration",r=>{let d="";r.on("data",c=>d+=c);r.on("end",()=>{const j=JSON.parse(d);console.log(j.issuer);console.log(j.userinfo_endpoint)})});'
   ```
   Both should start with `https://internal-identity.fe3dr.com`. If they show
   `http://keycloak.identity-internal.svc...` → Bug 2, `frontendUrl` is missing.

3. **Does userinfo work via the in-cluster URL?** (Bug 3 — confirmation)
   ```bash
   kubectl exec -n homechef "$BFF_POD" -c user-container -- node -e '
     const http=require("http"); const qs=require("querystring");
     const d=qs.stringify({grant_type:"client_credentials",client_id:"homechef-admin-bff",client_secret:process.env.KEYCLOAK_INTERNAL_CLIENT_SECRET,scope:"openid"});
     const r=http.request({hostname:"keycloak.identity-internal.svc.cluster.local",port:8080,path:"/realms/tesserix-internal/protocol/openid-connect/token",method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded","Content-Length":Buffer.byteLength(d)}},x=>{let b="";x.on("data",c=>b+=c);x.on("end",()=>{const t=JSON.parse(b).access_token;const u=http.request({hostname:"keycloak.identity-internal.svc.cluster.local",port:8080,path:"/realms/tesserix-internal/protocol/openid-connect/userinfo",method:"GET",headers:{Authorization:"Bearer "+t}},y=>{let bb="";y.on("data",c=>bb+=c);y.on("end",()=>console.log("userinfo",y.statusCode,bb.slice(0,200)))});u.end()})});r.write(d);r.end();'
   ```
   200 → in-cluster path works. 401 → re-run the bootstrap job; the realm
   `frontendUrl` is the most likely missing piece.

4. **Is the user in the realm with the admin role?** (Bug 4)
   ```bash
   kubectl exec -n identity-internal deploy/keycloak -c keycloak -- /opt/keycloak/bin/kcadm.sh \
     get users -r tesserix-internal -q email=samyak.rout@gmail.com \
     --no-config --server http://localhost:8080 \
     --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"
   ```
   No user → run the bootstrap job. User without `admin` role → bootstrap job
   will assign it. Multiple users for the same email → IdP linking confusion;
   manually delete the duplicate.

5. **Enable Keycloak event logging temporarily** if you need to see what's
   happening from Keycloak's side:
   ```bash
   # PUT /admin/realms/tesserix-internal { "eventsEnabled": true, "enabledEventTypes": [...] }
   # then GET /admin/realms/tesserix-internal/events?max=20
   ```
   Disable again when done — event logging is expensive on busy realms.

## What NOT to do (lessons from this debug)

- **Do not** set `KEYCLOAK_INTERNAL_INTERNAL_URL=""` in the BFF chart. That
  forces every back-channel call through the public path and triggers the
  Cloudflare header strip.
- **Do not** set `--hostname` on the Keycloak StatefulSet to "fix" dynamic
  URLs. Per-realm `frontendUrl` is the right knob.
- **Do not** add the `homechef-admin-bff` client config to `admin-bff`'s
  token-exchange policy unless you have a confirmed token-exchange use case.
  The error "Jwt issuer is not configured" is from `/userinfo`, not from
  RFC 8693 token exchange.
- **Do not** restart the BFF pod by deleting it manually. Use the Knative
  pattern: bump the
  `podAnnotations.client.knative.dev/updateTimestamp` parameter in the
  ArgoCD app and re-sync.
- **Do not** copy patterns from `mark8ly-auth-bff` — that uses a different
  image (`ghcr.io/tesserix/mark8ly-auth-bff`) with its own database and
  OpenFGA. The reference for shared
  `ghcr.io/tesseract-nexus/global-services/auth-bff` is `devai-auth-bff`.

## Relevant files

| Layer | File |
|-------|------|
| Realm definition (fresh imports) | `charts/thirdparty/identity-internal/templates/realm-configmap.yaml` |
| Idempotent realm patcher | `charts/thirdparty/identity-internal/templates/homechef-clients-bootstrap-job.yaml` |
| One-shot realm import | `charts/thirdparty/identity-internal/templates/realm-import-job.yaml` |
| Templated client secrets ESO | `charts/thirdparty/identity-internal/templates/client-secrets-external-secret.yaml` |
| Standalone client secrets ESO | `external-secrets/prod/identity-internal/externalsecret.yaml` |
| ArgoCD app for Keycloak | `argocd/prod/infrastructure/identity-internal.yaml` |
| BFF chart values (prod) | `charts/apps/homechef-auth-bff/values-prod.yaml` |
| BFF external secret | `charts/apps/homechef-auth-bff/templates/externalsecret.yaml` |
| BFF ArgoCD app + restart annotation | `argocd/prod/apps/homechef/homechef-auth-bff.yaml` |
| Admin portal Istio routing | `manifests/homechef-istio/virtualservice.yaml` (admin.fe3dr.com block) |
| Reference: working sibling BFF | `charts/apps/devai-auth-bff/values.yaml` |
