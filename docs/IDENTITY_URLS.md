# Identity Provider (Keycloak) URLs

All products share a single Keycloak instance (`identity-customer`) with product-specific domain aliases.
The issuer remains `identity.fanzonebattleground.com` across all aliases.

## Production

| Product | URL | Realm |
|---------|-----|-------|
| **Platform (Mark8ly)** | `https://identity.fanzonebattleground.com` | `tesserix-customer` |
| **HomeChef (Fe3dr)** | `https://identity.fe3dr.com` | `tesserix-customer` |
| **FanZone** | `https://identity.fanzonebattleground.com` | `tesserix-customer` |

### OIDC Discovery Endpoints (Prod)

| Product | Discovery URL |
|---------|---------------|
| Platform | `https://identity.fanzonebattleground.com/realms/tesserix-customer/.well-known/openid-configuration` |
| HomeChef | `https://identity.fe3dr.com/realms/tesserix-customer/.well-known/openid-configuration` |
| FanZone | `https://identity.fanzonebattleground.com/realms/tesserix-customer/.well-known/openid-configuration` |

### Admin Console (Prod)

| Product | Admin URL |
|---------|-----------|
| Platform | `https://identity.fanzonebattleground.com/admin` |
| HomeChef | `https://identity.fe3dr.com/admin` |
| FanZone | `https://identity.fanzonebattleground.com/admin` |

---

## DevTest

| Product | URL | Realm |
|---------|-----|-------|
| **Platform** | `https://devtest-customer-idp.tesserix.app` | `tesserix-customer` |
| **HomeChef (Fe3dr)** | `https://devtest-identity.fe3dr.com` | `tesserix-customer` |
| **FanZone** | `https://devtest-identity.fanzonebattleground.com` | `tesserix-customer` |

### OIDC Discovery Endpoints (DevTest)

| Product | Discovery URL |
|---------|---------------|
| Platform | `https://devtest-customer-idp.tesserix.app/realms/tesserix-customer/.well-known/openid-configuration` |
| HomeChef | `https://devtest-identity.fe3dr.com/realms/tesserix-customer/.well-known/openid-configuration` |
| FanZone | `https://devtest-identity.fanzonebattleground.com/realms/tesserix-customer/.well-known/openid-configuration` |

### Admin Console (DevTest)

| Product | Admin URL |
|---------|-----------|
| Platform | `https://devtest-customer-idp.tesserix.app/admin` |
| HomeChef | `https://devtest-identity.fe3dr.com/admin` |
| FanZone | `https://devtest-identity.fanzonebattleground.com/admin` |

---

## Internal IDP

Used for internal staff/admin authentication (separate Keycloak instance).

| Environment | URL | Realm |
|-------------|-----|-------|
| **Prod** | `https://internal-idp.mark8ly.com` | `tesserix-internal` |
| **Prod (HomeChef)** | `https://internal-identity.fe3dr.com` | `tesserix-internal` |
| **Prod (FanZone)** | `https://internal-identity.fanzonebattleground.com` | `tesserix-internal` |
| **DevTest** | `https://devtest-internal-idp.tesserix.app` | `tesserix-internal` |

## HomeChef Realm (Customer IDP)

Separate realm in the customer Keycloak for HomeChef/Fe3dr platform users.

| Environment | URL | Realm |
|-------------|-----|-------|
| **Prod** | `https://identity.fe3dr.com` | `homechef` |
| **DevTest** | `https://devtest-identity.fe3dr.com` | `homechef` |

### HomeChef OIDC Discovery

| Environment | Discovery URL |
|-------------|---------------|
| Prod | `https://identity.fe3dr.com/realms/homechef/.well-known/openid-configuration` |
| DevTest | `https://devtest-identity.fe3dr.com/realms/homechef/.well-known/openid-configuration` |

### HomeChef Realm Clients

| Client ID | Type | Purpose |
|-----------|------|---------|
| `homechef-web` | Public (PKCE) | React SPA frontend |
| `homechef-bff` | Confidential | Auth BFF (session management) |
| `homechef-mobile` | Public (PKCE) | Mobile app |
| `homechef-admin-bff` | Confidential | Auth BFF (admin context, in internal realm) |
| `homechef-admin-web` | Public (PKCE) | Admin dashboard (in internal realm) |

### HomeChef Realm Roles

| Role | Description |
|------|-------------|
| `customer` | Default role for customers |
| `chef` | Home cook / vendor role |
| `delivery_partner` | Delivery partner role |
| `admin` | HomeChef admin role |

---

## Architecture

```
                    Cloudflare (TLS termination)
                           |
              +------------+------------+
              |            |            |
         CF Tunnel    CF Tunnel    CF Tunnel
        (MARKETLY)   (FE3DR)     (FANZONE)
              |            |            |
              +------------+------------+
                           |
                  Istio Gateway (port 80)
                           |
              +------------+------------+
              |            |            |
       customer-idp-vs  identity-   identity-
                        fe3dr-vs   fanzone-vs
              |            |            |
              +------------+------------+
                           |
              keycloak.identity-customer:8080
```

### Key Details

- **Namespace**: `identity-customer`
- **Service**: `keycloak` (ClusterIP, port 8080)
- **Keycloak Version**: 26.0
- **Hostname Strict**: `false` (accepts requests on any hostname)
- **Issuer**: Dynamic per-domain (Keycloak derives from request Host header)
  - `https://identity.fanzonebattleground.com/realms/tesserix-customer` (marketplace)
  - `https://identity.fe3dr.com/realms/homechef` (HomeChef)
  - `https://identity.fanzonebattleground.com/realms/tesserix-customer` (FanZone)
- **Database**: `keycloak_customer` in `postgresql-global`
- **Istio Gateway**: `istio-ingress/tesseract-gateway`

### Cloudflare Configuration

| Domain | Zone | Tunnel | API Token (GCP Secret) |
|--------|------|--------|----------------------|
| `identity.fe3dr.com` | `fe3dr.com` | `PROD_FE3DR` | `prod-homechef-cloudflare-api-token` |
| `identity.fanzonebattleground.com` | `fanzonebattleground.com` | `PROD_TUNNEL` | (fanzone account) |
| `identity.fanzonebattleground.com` | `mark8ly.com` | `PROD_MARKETLY` | `prod-cloudflare-api-token` |
| `internal-identity.fe3dr.com` | `fe3dr.com` | `PROD_FE3DR` | `prod-homechef-cloudflare-api-token` |
| `internal-identity.fanzonebattleground.com` | `fanzonebattleground.com` | `PROD_TUNNEL` | (fanzone account) |

### GCP Secrets Required (HomeChef)

| Secret Name | Purpose |
|-------------|---------|
| `prod-homechef-keycloak-client-secret` | homechef-bff Keycloak client secret |
| `prod-homechef-internal-keycloak-client-secret` | homechef-admin-bff Keycloak client secret |
| `prod-homechef-bff-session-secret` | Auth BFF session encryption key |
| `prod-homechef-redis-password` | Redis password for BFF sessions |

### Relevant Files

| File | Purpose |
|------|---------|
| `charts/thirdparty/istio-config/values-prod.yaml` | `identityAliases` + `internalIdentityAliases` |
| `charts/thirdparty/istio-config/templates/virtual-services.yaml` | VirtualService templates |
| `argocd/prod/infrastructure/istio-auth-policies.yaml` | Auth policy (unauthenticated access) |
| `charts/thirdparty/identity-customer/values.yaml` | Keycloak Helm values (homechefRealm) |
| `charts/thirdparty/identity-internal/templates/realm-configmap.yaml` | Internal realm clients |
| `argocd/prod/infrastructure/identity-customer.yaml` | ArgoCD Application for Keycloak |
| `charts/apps/homechef-auth-bff/` | HomeChef Auth BFF Helm chart |
| `argocd/prod/apps/homechef/homechef-auth-bff.yaml` | ArgoCD Application for Auth BFF |
