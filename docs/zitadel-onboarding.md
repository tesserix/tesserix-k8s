# Zitadel — onboarding a product, and tenant self-service SSO

Two runbooks in one file, because they are the same system read from two ends.
Part 1 is what a **product team** does once, to move off Keycloak and start
authenticating against `https://auth.tesserix.app`. Part 2 is what the product
then offers **its own tenants**, so each can bring their own IdP — Google
Workspace, Entra, Okta, or a SAML appliance nobody has heard of — without any
change to the product or a deploy.

For what Zitadel *is* and how it is deployed, see [`zitadel.md`](zitadel.md).
This file assumes that is already running.

Every API path below was probed against the live instance on 2026-08-14
(Zitadel v4.15.3). Paths differ between major versions; re-probe before
trusting a path from an older copy of this file — an unauthenticated `POST`
returns `401` when the route exists and `404` when it does not.

---

## The model, in one paragraph

A tenant is a Zitadel **organization**. An IdP connection binds to an
organization, not to the instance, so one hostname federates a different IdP
per tenant. This is the whole reason Zitadel replaced Keycloak, where the same
shape needs a realm per tenant and a realm is a heavyweight object to create,
template and keep in step. A product is a **project**, and each deployable of
that product — web app, mobile app, backend API — is an **application** inside
that project. Projects and organizations are orthogonal: one project serves
every tenant, and a user in tenant A signing in to it gets tokens scoped to
tenant A's organization.

---

# Part 1 — Onboarding a product

## Step 0. Pick the token model before anything else

This decision determines every step after it, and changing it later means
reissuing every client credential.

**BFF with session cookies.** The browser never sees a token; a backend-for-frontend
holds the OIDC session and sets an HttpOnly cookie. Use this for anything with a
browser UI. The gateway sees no bearer token, so Step 3 does not apply to the
browser traffic — but it still applies to any service-to-service call.

**Bearer tokens.** The client sends `Authorization: Bearer <token>` and the API
verifies it. Use this for mobile apps, CLIs, machine-to-machine, and public APIs.
Step 3 is mandatory: without it the gateway rejects every request with `401 Jwt
issuer is not configured` **before your service is reached**, and the failure
looks like your service is broken.

Mixed is normal — a web UI on cookies and a mobile client on bearer tokens
against the same API.

## Step 1. Create the project and its applications

Console: *Projects → Create*, then *Applications → New* per deployable.
Via the API, with an `iam-admin` token (Part 2, Step 1):

```
POST /management/v1/projects
POST /management/v1/projects/{projectId}/apps/oidc
```

Choose the application type honestly, because it decides whether a client
secret exists at all:

| Client | Type | Auth method | Secret |
|---|---|---|---|
| Next.js / BFF | Web | `BASIC` or `PRIVATE_KEY_JWT` | yes |
| SPA, no backend | User Agent | PKCE, no secret | no |
| Mobile | Native | PKCE, no secret | no |
| Backend service | API | `PRIVATE_KEY_JWT` or client credentials | key or secret |

A public client (SPA, native) that is issued a secret is a public client with a
published secret. PKCE is not optional for those two.

Set redirect URIs to the exact production URLs plus any preview hostnames.
Zitadel matches them literally; a trailing-slash mismatch is a redirect failure
at sign-in with no useful error.

## Step 2. Store the credentials the way this estate stores credentials

Never in git, never in a ConfigMap, never in the Argo Application's inline
values. Client secrets go to GCP Secret Manager and reach the pod through
External Secrets, exactly like [`zitadel.md`](zitadel.md) describes for
Zitadel's own credentials:

```bash
printf '%s' "$CLIENT_SECRET" | gcloud secrets create prod-<product>-oidc-client-secret \
  --project=tesseracthub-480811 --replication-policy=automatic --data-file=-
```

Then an `ExternalSecret` in `external-secrets/prod/<product>/`, following the
pattern in `external-secrets/prod/zitadel/externalsecret.yaml`. Client IDs are
not secret and can live in values.

## Step 3. Register the issuer at the ingress gateway

**Skip this and bearer-token auth cannot work, no matter what your service
does.** Istio merges `jwtRules` across every `RequestAuthentication` selecting
the same gateway workload. A JWT whose issuer matches no rule is rejected at the
gateway with `401 Jwt issuer is not configured`, before the upstream sees it.
The symptom is "auth is broken for exactly one client", which sends people
looking at the client.

Add an entry to `extraGip` in `argocd/prod/infrastructure/istio-auth-policies.yaml`:

```yaml
        extraGip:
          - name: -zitadel
            issuer: "https://auth.tesserix.app"
            jwksUri: "https://auth.tesserix.app/oauth/v2/keys"
            audiences:
              - "<projectId>"          # Zitadel puts the project ID in `aud`
              - "<clientId>"
            restrictToHosts:
              - "api.<product>.tesserix.app"
```

`restrictToHosts` is not decoration. Validating a token at the gateway turns it
into a request principal, and `allow-authenticated-api` honours a request
principal on **every host on that gateway**. Without the paired
`deny-foreign-hosts` rule that `restrictToHosts` generates, a Zitadel token
minted for your product is accepted by every other product behind the same
gateway.

The `extraGip` key is named for its first use (extra Google Identity Platform
projects). It is generic — issuer, JWKS URI, audiences, hosts — and reusing it
is correct.

## Step 4. Allow the product's hostname at the gateway

The gateway host allowlist is evaluated **before** any AuthorizationPolicy in
your namespace. A hostname missing from it answers every request with
`403 RBAC: access denied` while your pods are healthy and serving — this cost an
afternoon on `auth.tesserix.app` itself.

Add to `frontendApps` in the same file:

```yaml
          - name: <product>
            label: <product>
            hosts:
              - "<product>.tesserix.app"
```

Omit `namespace:` if your chart already ships its own pod-level
AuthorizationPolicy; include it to have the shared chart generate one.

Note that under ambient mesh, **ztunnel cannot enforce HTTP attributes**. A
policy using `paths`, `methods` or `hosts` that is enforced by ztunnel rather
than by a gateway or waypoint silently drops those rules — within an ALLOW
policy that makes it more restrictive than written, so it fails closed. Istio
reports this on the resource as `reason: UnsupportedValue`; check it after
adding any path-based rule in a namespace.

## Step 5. Wire the application

Discovery is at `https://auth.tesserix.app/.well-known/openid-configuration`.
Read the endpoints from there rather than hardcoding them.

Confirmed supported on this instance: `authorization_code`, `refresh_token`,
`client_credentials`, `urn:ietf:params:oauth:grant-type:jwt-bearer`, device
code; PKCE; `private_key_jwt`; `RS256`/`ES256`/`EdDSA`.

Two Zitadel-specific scopes matter more than the standard set:

- `urn:zitadel:iam:org:project:id:{projectId}:aud` — adds your project to the
  token audience. Your API validates `aud`; without this scope the token your
  own frontend obtained is not valid for your own backend.
- `urn:zitadel:iam:org:id:{orgId}` — pins the sign-in to one organization,
  bypassing domain discovery. Use it when the product already knows the tenant
  from the hostname or path; omit it to let the user's email domain choose
  (Part 2).

Backends should verify locally against the JWKS — fetch `/oauth/v2/keys`, cache
it, honour `kid`. Reserve `/oauth/v2/introspect` for opaque tokens or where
instant revocation matters; it puts a network hop in every request.

Login UI is **v2 and required** on this instance (`Features.LoginV2.Required`),
served from `https://auth.tesserix.app/ui/v2/login`. Do not build against v1
paths; they are deprecated upstream.

## Step 6. Verify, in this order

Each step isolates one layer, so a failure tells you which one:

```bash
# 1. Instance reachable and issuer correct
curl -s https://auth.tesserix.app/.well-known/openid-configuration | jq .issuer

# 2. Your hostname passes the gateway allowlist (Step 4) — not a 403
curl -s -o /dev/null -w '%{http_code}\n' https://<product>.tesserix.app/

# 3. Sign in through a browser, capture an access token

# 4. The gateway accepts the issuer (Step 3) — a 401 with
#    "Jwt issuer is not configured" means extraGip has not synced
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" https://<product>.tesserix.app/api/health

# 5. Your API accepts the audience — a 403 here with a 200 at step 4 means the
#    project-audience scope is missing from the client's scope list
```

Argo syncs on a poll interval, so allow a few minutes between merging a
`istio-auth-policies` change and testing it. Gateway config propagates to each
gateway pod independently; a policy can pass on one pod and not yet on another,
which shows up as an intermittent 403 that resolves itself.

---

# Part 2 — Tenant self-service SSO

The goal: a tenant admin signs up, proves they own their domain, connects their
own IdP, and from then on their users sign in with it — with no ticket, no
deploy, and no platform engineer involved. Enterprise tenants get SAML and LDAP
on the same path.

## The shape

```
Tenant signs up in your product
  → product creates a Zitadel organization for them          (Step 2)
  → tenant admin verifies their email domain                  (Step 3)
  → tenant admin connects their IdP                           (Step 4)
  → IdP is bound to that org's login policy                   (Step 5)
  → any user at that domain is routed to that IdP             (Step 6)
```

Steps 3–5 are the tenant's own work. Expose them in your product's admin UI by
calling the API with the org's context, or hand the tenant admin an
`ORG_OWNER` grant and let them use the Zitadel console directly. The console
route costs no engineering and is the right first answer; build the in-product
UI when tenants ask for it.

## Step 1. Get a platform token

Everything the platform does on a tenant's behalf uses the `iam-admin` machine
user. Its key is written **once** into the `iam-admin` secret in the `zitadel`
namespace, key `iam-admin.json`, when the setup Job first runs. Deleting the
secret does not regenerate it — issue a new key in the console.

Exchange the key for a token with the JWT-profile grant:

```
POST https://auth.tesserix.app/oauth/v2/token
  grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer
  assertion=<JWT signed with the iam-admin private key>
  scope=openid urn:zitadel:iam:org:project:id:zitadel:aud
```

That last scope is what makes the token valid against Zitadel's own management
API. Omit it and every call below returns 403 with a token that looks fine.

To act inside a tenant's organization, send its ID in the `x-zitadel-orgid`
header. Every `/management/v1/...` call is org-scoped by that header; forget it
and you silently operate on the platform's own org.

## Step 2. Create the organization

```
POST /v2/organizations
```

or the v1 equivalent `POST /management/v1/orgs`. Do this at tenant signup, in
the same transaction as your own tenant record — an org without a tenant row is
an orphan nobody will find again.

Store the returned organization ID on your tenant record. It is the join key
between your database and Zitadel for everything afterwards, and there is no
cheap way to look it up later by your own tenant name.

Make the tenant's first user an org owner so they can manage their own IdPs:

```
POST /v2/users/human
POST /management/v1/orgs/me/members        # role ORG_OWNER, x-zitadel-orgid: <orgId>
```

## Step 3. Verify the tenant's domain

Domain discovery routes users by email domain, so an unverified domain would let
any tenant claim `@gmail.com` — or a competitor's domain — and capture their
sign-ins. Verification is what makes it safe.

```
POST /management/v1/orgs/me/domains                                   # add
POST /management/v1/orgs/me/domains/{domain}/validation/_generate     # get challenge
POST /management/v1/orgs/me/domains/{domain}/validation/_validate     # check it
POST /management/v1/orgs/me/domains/{domain}/_set_primary             # optional
```

`_generate` returns a DNS TXT or HTTP challenge; the tenant publishes it and you
call `_validate`. Surface the challenge and a *Check now* button in your admin
UI — DNS propagation means the first check often fails, and a tenant who is told
only "failed" will open a ticket.

## Step 4. Connect the tenant's IdP

All of these are `POST` with `x-zitadel-orgid: <orgId>`, and all exist on this
instance:

| Tenant has | Endpoint | They must give you |
|---|---|---|
| Generic OIDC | `/management/v1/idps/oidc` | issuer, client ID, client secret, scopes |
| SAML 2.0 | `/management/v1/idps/saml` | IdP metadata XML or URL |
| Entra ID / Azure AD | `/management/v1/idps/azure` | tenant ID, client ID, secret |
| Google Workspace | `/management/v1/idps/google` | client ID, secret |
| GitHub | `/management/v1/idps/github` | client ID, secret |
| LDAP / AD | `/management/v1/idps/ldap` | server URL, bind DN, base DN, attribute map |
| Generic OAuth2 | `/management/v1/idps/oauth` | endpoints, client ID, secret |
| Pre-issued JWT | `/management/v1/idps/jwt` | issuer, JWKS URI, header name |

Console equivalent: *Organization → Identity Providers*.

Notes that come up on every enterprise onboarding:

**SAML.** The tenant's IdP admin needs your SP metadata — ACS URL and entity ID,
both derived from the IdP instance you just created, so create it first and read
the values back. Enterprise IdP teams work in change windows; expect days, not
minutes, and make the connection visible as *pending* in your UI so the tenant
can see whose turn it is.

**LDAP** requires network reachability from Zitadel's pods to the tenant's
directory. That is a firewall and egress-policy conversation, not a
self-service one. Treat LDAP as assisted onboarding.

**Entra ID** is a distinct endpoint from generic OIDC because of its tenant-ID
routing and its non-standard claims. Use `/idps/azure`, not `/idps/oidc`, or
group and email claims arrive in the wrong shape.

Set `autoRegister` deliberately. On, a user who authenticates at the tenant's
IdP is provisioned in that org on first sign-in — which is what most tenants
want and is also how an over-broad IdP silently fills an org with people who
should not be in it. Off, users must be invited first.

## Step 5. Bind the IdP to the org's login policy

Creating an IdP does **not** make it usable. It has to be added to the
organization's login policy:

```
POST /management/v1/policies/login/idps        # x-zitadel-orgid: <orgId>
```

This is the single most common thing to miss. Symptom: the IdP exists in the
console, the tenant swears they configured it, and the login screen never offers
it.

While you are there, per-organization policy overrides everything in
`DefaultInstance`. A tenant can require MFA, disable password login entirely, or
set their own lockout rules without any change on the platform side. That is the
right answer to "can we enforce our security policy?" — yes, on their org, by
themselves.

## Step 6. Domain discovery does the routing

`LoginPolicy.AllowDomainDiscovery: true` is set instance-wide. A user types
`alice@tenant.com`, Zitadel matches the verified domain to the organization, and
sends them to that organization's IdP. One hostname, every tenant's SSO, no
tenant selector in your UI.

Where the product already knows the tenant — a subdomain, a path prefix, an
invitation link — pass `urn:zitadel:iam:org:id:{orgId}` in the scope instead and
skip discovery entirely. It is a better experience: the user never sees a
generic login page.

## Step 7. Claims your product actually needs

Tokens do not carry your application's roles by default. Two mechanisms:

- **Project roles and grants.** Define roles on the project, grant them to an
  organization, assign them to users. They appear in the token under
  `urn:zitadel:iam:org:project:roles`. This is the right tool for coarse
  authorization.
- **Actions v2** (`POST /v2/actions/targets`) for anything computed — a custom
  claim from your own database, provisioning a row on first sign-in, enriching a
  token with tenant metadata.

Actions are runtime objects created through the API. They cannot be declared in
the Helm chart, so whatever you build, script it and keep the script in the
product repo. An Action that exists only in the console is one console mistake
away from gone, with no diff to review and nothing to restore from.

---

## Failure modes, and what they actually mean

| What you see | Cause |
|---|---|
| `401 Jwt issuer is not configured` | Issuer not in `extraGip` (Part 1, Step 3) |
| `403 RBAC: access denied` | Hostname not in `frontendApps` (Part 1, Step 4) |
| 403 with a valid token that works elsewhere | Missing project-audience scope |
| Token accepted by another product | `restrictToHosts` not set |
| IdP configured but never offered at login | Not bound to the login policy (Part 2, Step 5) |
| Redirect fails at sign-in, no clear error | Redirect URI mismatch — Zitadel matches literally |
| Management API 403 with a good token | Missing `...:project:id:zitadel:aud` scope |
| Operating on the wrong tenant | `x-zitadel-orgid` header omitted |
| Intermittent 403 that clears itself | Gateway config still propagating across pods |
| Path-based policy not enforced | ztunnel cannot enforce HTTP attributes; check `reason: UnsupportedValue` |

## Onboarding checklist

- [ ] Token model chosen (BFF cookies / bearer / mixed)
- [ ] Project and applications created, correct client types, PKCE on public clients
- [ ] Client secret in GCP Secret Manager, reaching the pod via External Secrets
- [ ] Issuer in `extraGip` **with** `restrictToHosts`
- [ ] Hostname in `frontendApps`
- [ ] Project-audience scope in the client's scope list
- [ ] Backend verifies against JWKS, caches it, honours `kid`
- [ ] Login v2 paths only
- [ ] Verification steps 1–5 pass end to end
- [ ] Tenant signup creates a Zitadel org and stores its ID on the tenant record
- [ ] Domain verification exposed in the product UI, with a re-check action
- [ ] IdP connection UI, or `ORG_OWNER` granted so the tenant can use the console
- [ ] IdP binding to the login policy is part of the flow, not a manual step
- [ ] Actions scripted and committed, not created by hand in the console
