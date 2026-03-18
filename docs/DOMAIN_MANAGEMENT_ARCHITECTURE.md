# Domain Management Architecture

> **Version**: 1.1
> **Last Updated**: January 2026
> **Status**: Implemented

## Table of Contents

1. [Overview](#overview)
2. [Architecture Components](#architecture-components)
3. [Domain Types](#domain-types)
4. [Request Flow](#request-flow)
5. [NS Delegation (Automatic SSL)](#ns-delegation-automatic-ssl)
6. [Onboarding Flow](#onboarding-flow)
7. [Migration: Built-in to Custom Domain](#migration-built-in-to-custom-domain)
8. [Data Model](#data-model)
9. [API Reference](#api-reference)
10. [Configuration](#configuration)
11. [Troubleshooting](#troubleshooting)

---

## Overview

The Tesserix platform supports two types of storefront domains:

| Domain Type | Example | Use Case |
|-------------|---------|----------|
| **Built-in** | `awesome-store.tesserix.app` | Instant setup, no DNS config needed |
| **Custom** | `store.example.com` | Branded experience, SEO benefits |

Both domain types can coexist, allowing merchants to:
- Start immediately with a built-in domain
- Add custom domains later without downtime
- Gradually migrate traffic with redirects
- Use multiple custom domains for different markets

---

## Architecture Components

### Service Responsibilities

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         DOMAIN MANAGEMENT SERVICES                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────┐      ┌─────────────────────────┐           │
│  │   TENANT ROUTER SERVICE │      │  CUSTOM DOMAIN SERVICE  │           │
│  │   (global namespace)    │      │  (marketplace namespace)│           │
│  ├─────────────────────────┤      ├─────────────────────────┤           │
│  │ • Built-in domains      │      │ • Custom domain mgmt    │           │
│  │ • *.tesserix.app        │      │ • DNS verification      │           │
│  │ • Instant provisioning  │      │ • SSL certificates      │           │
│  │ • Wildcard certificate  │      │ • Per-domain certs      │           │
│  │ • Slug → Tenant mapping │      │ • Domain → Tenant map   │           │
│  └─────────────────────────┘      └─────────────────────────┘           │
│              │                                │                          │
│              └────────────┬───────────────────┘                          │
│                           │                                              │
│                           ▼                                              │
│              ┌─────────────────────────┐                                 │
│              │     ISTIO GATEWAY       │                                 │
│              │   (istio-ingress ns)    │                                 │
│              ├─────────────────────────┤                                 │
│              │ • TLS termination       │                                 │
│              │ • Host-based routing    │                                 │
│              │ • Certificate mounting  │                                 │
│              └─────────────────────────┘                                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Tenant Router Service

**Purpose**: Manages built-in platform domains (`*.tesserix.app`)

| Feature | Description |
|---------|-------------|
| **Subdomain Provisioning** | Creates `{slug}.tesserix.app` for storefronts |
| **Admin Domain** | Creates `{slug}-admin.tesserix.app` for admin panels |
| **Istio Resources** | Patches Gateway, creates VirtualServices |
| **Tenant Resolution** | Resolves slug → tenant_id for storefronts |
| **Event-Driven** | Subscribes to `TenantCreatedEvent` via NATS |

**Endpoint**: `http://tenant-router-service.marketplace.svc.cluster.local:8089`

### Custom Domain Service

**Purpose**: Manages custom branded domains (e.g., `store.example.com`)

| Feature | Description |
|---------|-------------|
| **Domain Registration** | Validates and stores custom domain |
| **DNS Verification** | Verifies ownership via TXT/CNAME records |
| **SSL Certificates** | Provisions Let's Encrypt certificates via cert-manager |
| **Istio Routing** | Creates VirtualService, patches Gateway |
| **Keycloak Integration** | Updates OAuth redirect URIs |
| **Health Monitoring** | Periodic health checks on active domains |

**Endpoint**: `http://custom-domain-service.marketplace.svc.cluster.local:8093`

---

## Domain Types

### Built-in Domains

```
Format: {slug}.tesserix.app
        {slug}-admin.tesserix.app

Examples:
  Storefront: awesome-store.tesserix.app
  Admin:      awesome-store-admin.tesserix.app
```

**Characteristics**:
- ✅ Instant availability (no DNS setup)
- ✅ Wildcard SSL certificate (already provisioned)
- ✅ Automatic provisioning on tenant creation
- ❌ Not brandable (shows tesserix.app)

### Custom Domains

```
Format: {subdomain}.{domain}.{tld}
        {domain}.{tld}

Examples:
  store.example.com
  shop.mybrand.io
  www.awesome-store.com
```

**Characteristics**:
- ✅ Fully brandable
- ✅ SEO benefits (own domain authority)
- ✅ Professional appearance
- ⚠️ Requires DNS configuration
- ⚠️ SSL provisioning takes 1-5 minutes

---

## Request Flow

### Built-in Domain Flow

```
┌──────────────────────────────────────────────────────────────────┐
│  User visits: awesome-store.tesserix.app                          │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Istio Gateway                                                    │
│  - Matches *.tesserix.app wildcard server                         │
│  - TLS termination with wildcard certificate                      │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  VirtualService: storefront-vs                                    │
│  - Routes to storefront service                                   │
│  - No header injection (subdomain extracted client-side)          │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Storefront Application                                           │
│  1. Extract slug from subdomain: "awesome-store"                  │
│  2. Call Tenant Router: GET /api/v1/hosts/awesome-store           │
│  3. Receive tenant_id, storefront_id                              │
│  4. Render storefront with tenant context                         │
└──────────────────────────────────────────────────────────────────┘
```

### Custom Domain Flow

```
┌──────────────────────────────────────────────────────────────────┐
│  User visits: store.example.com                                   │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  DNS Resolution                                                   │
│  store.example.com → CNAME → proxy.tesserix.app                   │
│  proxy.tesserix.app → A → Istio Gateway IP                        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Istio Gateway                                                    │
│  - Matches store.example.com (patched by custom-domain-service)   │
│  - TLS termination with domain-specific certificate               │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  VirtualService: store-example-com-vs                             │
│  - Injects headers:                                               │
│    • x-tenant-id: <uuid>                                          │
│    • x-tenant-slug: awesome-store                                 │
│    • x-custom-domain: store.example.com                           │
│  - Routes to storefront service                                   │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Storefront Application                                           │
│  1. Read x-tenant-id header (injected by Istio)                   │
│  2. Read x-tenant-slug header                                     │
│  3. Render storefront with tenant context (no API call needed!)   │
└──────────────────────────────────────────────────────────────────┘
```

### Storefront Resolution Logic

```typescript
// lib/tenant.ts - Resolution Priority

async function resolveTenantSmart(host: string) {
  // 1. FASTEST: Check Istio-injected headers (custom domains)
  const fromHeaders = await resolveTenantFromHeaders();
  if (fromHeaders) return { info: fromHeaders, source: 'header' };

  // 2. FAST: Extract from subdomain (*.tesserix.app)
  if (host.endsWith('.tesserix.app')) {
    const slug = host.split('.')[0];
    const fromSubdomain = await resolveTenantInfo(slug);
    if (fromSubdomain) return { info: fromSubdomain, source: 'subdomain' };
  }

  // 3. FALLBACK: Query custom-domain-service directly
  const fromCustomDomain = await resolveTenantFromCustomDomain(host);
  if (fromCustomDomain) return { info: fromCustomDomain, source: 'custom-domain-lookup' };

  return { info: null, source: null };
}
```

---

## NS Delegation (Automatic SSL)

### Overview

NS Delegation enables **fully automatic SSL certificate management** for custom domains. Instead of using HTTP-01 challenges (which require the domain to point to our servers first), customers delegate the `_acme-challenge` subdomain to our nameservers, allowing us to handle DNS-01 challenges automatically.

### Benefits

| Feature | HTTP-01 (Traditional) | NS Delegation |
|---------|----------------------|---------------|
| **Certificate timing** | After CNAME setup | Before domain points to us |
| **Renewal reliability** | Depends on routing | Always works |
| **Wildcard certs** | Not possible | Supported |
| **Customer action** | CNAME + TXT verification | NS records (one-time) |
| **Failure modes** | Many (routing, DNS, pods) | Minimal |

### Architecture

```
Customer's DNS (GoDaddy, Cloudflare, etc.)
┌──────────────────────────────────────────────────────────────────┐
│  store.example.com                CNAME  proxy.tesserix.app      │
│  _acme-challenge.store.example.com  NS   ns1.tesserix.app        │
│  _acme-challenge.store.example.com  NS   ns2.tesserix.app        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
Tesserix Managed DNS (Google Cloud DNS)
┌──────────────────────────────────────────────────────────────────┐
│  Zone: acme.tesserix.app                                          │
│                                                                   │
│  TXT records for ACME challenges created/deleted automatically    │
│  by cert-manager during certificate issuance/renewal              │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
cert-manager DNS-01 Solver
┌──────────────────────────────────────────────────────────────────┐
│  1. Certificate requested for store.example.com                   │
│  2. cert-manager creates TXT record in Cloud DNS                  │
│  3. Let's Encrypt queries _acme-challenge.store.example.com       │
│  4. NS delegation routes query to ns1/ns2.tesserix.app            │
│  5. Cloud DNS responds with TXT record                            │
│  6. Certificate issued, TXT record cleaned up                     │
└──────────────────────────────────────────────────────────────────┘
```

### Customer Setup Instructions

When customers register a custom domain, they receive instructions to add these DNS records:

#### Step 1: Enable Automatic SSL (Recommended)

Add NS records to delegate ACME challenges to Tesserix:

| Type | Host | Value |
|------|------|-------|
| NS | `_acme-challenge.store.example.com` | `ns1.tesserix.app` |
| NS | `_acme-challenge.store.example.com` | `ns2.tesserix.app` |

#### Step 2: Point Domain to Platform

Add CNAME record to route traffic:

| Type | Host | Value |
|------|------|-------|
| CNAME | `store.example.com` | `proxy.tesserix.app` |

### Verification Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  NS Delegation Verification Flow                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 1: Customer adds NS records at registrar                   │
│  _acme-challenge.store.example.com NS ns1.tesserix.app           │
│  _acme-challenge.store.example.com NS ns2.tesserix.app           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 2: NS Verification Worker (runs every 5 minutes)           │
│  • Performs NS lookup: dig NS _acme-challenge.store.example.com  │
│  • Checks if NS records point to ns1/ns2.tesserix.app            │
│  • Marks ns_delegation_verified = true if matched                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 3: Certificate Provisioning (DNS-01)                       │
│  • Create Certificate resource with NS delegation issuer         │
│  • cert-manager creates TXT record in Cloud DNS zone             │
│  • Let's Encrypt validates via DNS-01                            │
│  • Certificate issued (typically 30-60 seconds)                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 4: Domain Ready                                            │
│  • Certificate stored in Kubernetes secret                       │
│  • Gateway configured when CNAME verification passes             │
│  • Domain fully operational                                      │
└─────────────────────────────────────────────────────────────────┘
```

### Certificate Issuers

Three ClusterIssuers are available for different scenarios:

| Issuer | Challenge Type | Use Case |
|--------|----------------|----------|
| `letsencrypt-prod` | DNS-01 (Cloudflare) | Platform domains (`*.tesserix.app`) |
| `letsencrypt-prod-ns-delegation` | DNS-01 (Cloud DNS) | NS-delegated custom domains |
| `letsencrypt-prod-http01` | HTTP-01 (Istio) | Fallback for domains without NS delegation |

### Solver Selection Logic

The custom-domain-service selects the appropriate certificate issuer:

```go
func selectIssuer(domain *CustomDomain) string {
    // Priority 1: NS delegation verified - use DNS-01 (most reliable)
    if domain.NSDelegationVerified {
        return "letsencrypt-prod-ns-delegation"
    }

    // Priority 2: Cloudflare tunnel enabled - no cert needed (edge SSL)
    if config.CloudflareTunnelEnabled {
        return "" // Cloudflare handles SSL
    }

    // Priority 3: Fallback to HTTP-01
    return "letsencrypt-prod-http01"
}
```

### Configuration

#### cert-manager Issuers

```yaml
# values.yaml for cert-manager-issuers
nsDelegation:
  enabled: true
  cloudDNS:
    project: "tesseracthub-480811"
    hostedZoneName: "acme-challenges"
  nameservers:
    - ns1.tesserix.app
    - ns2.tesserix.app
```

#### Custom Domain Service

```yaml
# values.yaml for custom-domain-service
ssl:
  nsDelegationIssuerName: "letsencrypt-prod-ns-delegation"

nsDelegation:
  enabled: true
  nameservers:
    - ns1.tesserix.app
    - ns2.tesserix.app
  verificationInterval: "5m"
  maxAttempts: 100
```

### Database Fields

Additional fields in `custom_domains` table for NS delegation:

```sql
-- NS Delegation tracking
ns_delegation_enabled       BOOLEAN DEFAULT FALSE,
ns_delegation_verified      BOOLEAN DEFAULT FALSE,
ns_delegation_verified_at   TIMESTAMP,
ns_delegation_check_attempts INT DEFAULT 0,
ns_records                  TEXT[], -- Expected NS records
acme_zone_id                VARCHAR(100) -- Cloud DNS zone ID
```

### API Endpoints

#### Get NS Delegation Status
```http
GET /api/v1/domains/{id}/ns-delegation
X-Tenant-ID: {tenant-uuid}

Response 200:
{
  "enabled": true,
  "verified": false,
  "nameservers": ["ns1.tesserix.app", "ns2.tesserix.app"],
  "challenge_host": "_acme-challenge.store.example.com",
  "instructions": {
    "type": "NS",
    "host": "_acme-challenge.store.example.com",
    "values": ["ns1.tesserix.app", "ns2.tesserix.app"]
  }
}
```

#### Verify NS Delegation
```http
POST /api/v1/domains/{id}/ns-delegation/verify
X-Tenant-ID: {tenant-uuid}

Response 200:
{
  "verified": true,
  "message": "NS delegation verified successfully"
}
```

#### Enable NS Delegation
```http
POST /api/v1/domains/{id}/ns-delegation/enable
X-Tenant-ID: {tenant-uuid}

Response 200:
{
  "enabled": true,
  "instructions": {
    "type": "NS",
    "host": "_acme-challenge.store.example.com",
    "values": ["ns1.tesserix.app", "ns2.tesserix.app"]
  }
}
```

### Troubleshooting NS Delegation

#### NS records not detected

**Cause**: DNS propagation delay or incorrect records

**Solution**:
```bash
# Check NS records
dig NS _acme-challenge.store.example.com

# Expected output should include:
# _acme-challenge.store.example.com. NS ns1.tesserix.app.
# _acme-challenge.store.example.com. NS ns2.tesserix.app.
```

#### Certificate issuance failing with DNS-01

**Cause**: Cloud DNS zone misconfiguration or permissions

**Solution**:
```bash
# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager -f | grep -i "dns01"

# Check Certificate status
kubectl describe certificate <domain-name> -n istio-ingress

# Verify Cloud DNS service account permissions
gcloud dns record-sets list --zone=acme-challenges
```

---

## Onboarding Flow

### Phase 1: Tenant Creation (Built-in Domain)

When a user completes onboarding, the system **always creates a built-in domain first**:

```
┌─────────────────────────────────────────────────────────────────┐
│                    ONBOARDING COMPLETION                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 1: Tenant Service                                          │
│  • Create tenant record with slug                                │
│  • Publish TenantCreatedEvent to NATS                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 2: Tenant Router Service (Event Subscriber)                │
│  • Receive TenantCreatedEvent                                    │
│  • Create TenantHostRecord in database                           │
│  • Configure Istio VirtualService for storefront                 │
│  • Configure Istio VirtualService for admin                      │
│  • No certificate needed (uses wildcard)                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Result: Tenant has working URLs immediately                     │
│  • Storefront: {slug}.tesserix.app                               │
│  • Admin: {slug}-admin.tesserix.app                              │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 2: Optional Custom Domain (During or After Onboarding)

```
┌─────────────────────────────────────────────────────────────────┐
│  User enters custom domain in onboarding or admin settings       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 1: Domain Registration                                     │
│  POST /api/v1/domains                                            │
│  • Validate domain format (RFC 1035/1123)                        │
│  • Check against blocked domains                                 │
│  • Check tenant domain limit                                     │
│  • Create pending domain record                                  │
│  • Return DNS verification instructions                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 2: User Configures DNS                                     │
│  At domain registrar (Cloudflare, GoDaddy, etc.):                │
│  • Add CNAME: store.example.com → proxy.tesserix.app             │
│  • Add TXT: _tesserix.store.example.com → verify-token           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 3: DNS Verification (Automated Worker)                     │
│  • DNS Verification Worker checks every 5 minutes                │
│  • Verifies TXT record presence                                  │
│  • Marks dns_verified = true                                     │
│  • Triggers SSL provisioning                                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 4: SSL Certificate Provisioning                            │
│  • Create cert-manager Certificate resource                      │
│  • Let's Encrypt issues certificate (1-5 minutes)                │
│  • Certificate stored in Kubernetes secret                       │
│  • Secret mounted to Istio Gateway                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 5: Routing Configuration                                   │
│  • Create VirtualService for custom domain                       │
│  • Patch Gateway to add domain to HTTPS server                   │
│  • Update Keycloak redirect URIs                                 │
│  • Mark domain as active                                         │
│  • Notify tenant service                                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Result: Custom domain is live                                   │
│  • Both domains now work in parallel                             │
│  • User can set primary domain preference                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Migration: Built-in to Custom Domain

### Scenario

A merchant started with `awesome-store.tesserix.app` and now wants to use `store.example.com`.

### Migration Steps

| Phase | Action | Result |
|-------|--------|--------|
| **1. Add Domain** | Register custom domain via Admin Settings | Both domains work |
| **2. Verify DNS** | Configure CNAME and TXT records | DNS verified |
| **3. SSL Ready** | Automatic certificate provisioning | HTTPS enabled |
| **4. Set Primary** | Mark custom domain as primary | SEO canonical set |
| **5. Redirect** | Optional: Enable redirect from old domain | Traffic consolidated |

### Parallel Operation Period

During migration, **both domains work simultaneously**:

```
                    ┌─────────────────────────┐
                    │     PARALLEL PERIOD      │
                    └─────────────────────────┘

  awesome-store.tesserix.app          store.example.com
            │                                │
            │         BOTH ACTIVE            │
            │         SAME CONTENT           │
            │         SAME TENANT            │
            ▼                                ▼
        ┌─────────────────────────────────────────┐
        │              STOREFRONT                  │
        │         tenant_id: abc-123               │
        └─────────────────────────────────────────┘
```

### Setting Primary Domain

```
PATCH /api/v1/domains/{id}
{
  "primary_domain": true
}
```

**Effects**:
- Updates `<link rel="canonical">` in storefront
- Updates SEO sitemap generation
- Updates transactional email links
- Notifies tenant service of preference

### Optional Redirect Configuration

```
PATCH /api/v1/tenants/{id}/domains/redirect
{
  "source": "awesome-store.tesserix.app",
  "target": "store.example.com",
  "redirect_type": "301"
}
```

**Result**: All traffic to built-in domain redirects to custom domain with 301 (permanent redirect).

---

## Data Model

### Tenant Router Service

```sql
-- tenant_host_records table
CREATE TABLE tenant_host_records (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL,
    slug            VARCHAR(50) UNIQUE NOT NULL,
    admin_host      VARCHAR(255) NOT NULL,
    storefront_host VARCHAR(255) NOT NULL,
    status          VARCHAR(20) DEFAULT 'active',
    created_at      TIMESTAMP DEFAULT NOW(),
    updated_at      TIMESTAMP DEFAULT NOW()
);

-- Index for fast tenant lookup
CREATE INDEX idx_tenant_host_tenant_id ON tenant_host_records(tenant_id);
CREATE INDEX idx_tenant_host_slug ON tenant_host_records(slug);
```

### Custom Domain Service

```sql
-- custom_domains table
CREATE TABLE custom_domains (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id               UUID NOT NULL,
    tenant_slug             VARCHAR(50) NOT NULL,
    domain                  VARCHAR(255) UNIQUE NOT NULL,
    target_type             VARCHAR(20) NOT NULL, -- 'storefront', 'admin', 'api'

    -- DNS Verification
    dns_verified            BOOLEAN DEFAULT FALSE,
    dns_verification_token  VARCHAR(255),
    dns_last_checked_at     TIMESTAMP,
    dns_verification_method VARCHAR(20) DEFAULT 'txt', -- 'txt', 'cname'

    -- SSL Certificate
    ssl_status              VARCHAR(20) DEFAULT 'pending',
    ssl_secret_name         VARCHAR(255),
    ssl_expires_at          TIMESTAMP,
    ssl_last_checked_at     TIMESTAMP,

    -- Routing
    routing_status          VARCHAR(20) DEFAULT 'pending',
    virtual_service_name    VARCHAR(255),
    gateway_configured      BOOLEAN DEFAULT FALSE,

    -- Keycloak
    keycloak_configured     BOOLEAN DEFAULT FALSE,

    -- Domain Settings
    primary_domain          BOOLEAN DEFAULT FALSE,
    redirect_www            BOOLEAN DEFAULT TRUE,
    force_https             BOOLEAN DEFAULT TRUE,
    include_www             BOOLEAN DEFAULT TRUE,

    -- Status
    status                  VARCHAR(20) DEFAULT 'pending',
    status_message          TEXT,
    created_at              TIMESTAMP DEFAULT NOW(),
    updated_at              TIMESTAMP DEFAULT NOW(),
    deleted_at              TIMESTAMP
);

-- Indexes
CREATE INDEX idx_custom_domains_tenant_id ON custom_domains(tenant_id);
CREATE INDEX idx_custom_domains_domain ON custom_domains(domain);
CREATE INDEX idx_custom_domains_status ON custom_domains(status);
```

### Domain Status Lifecycle

```
pending → verifying → provisioning → active
    │         │            │
    │         │            └──→ failed (ssl/routing error)
    │         └──→ failed (dns verification failed)
    └──→ deleted (user cancelled)
```

---

## API Reference

### Custom Domain Service APIs

#### Create Domain
```http
POST /api/v1/domains
Content-Type: application/json
X-Tenant-ID: {tenant-uuid}

{
  "domain": "store.example.com",
  "target_type": "storefront"
}

Response 201:
{
  "id": "domain-uuid",
  "domain": "store.example.com",
  "status": "pending",
  "verification_record": {
    "type": "TXT",
    "host": "_tesserix.store.example.com",
    "value": "tesserix-verify-abc123"
  }
}
```

#### List Domains
```http
GET /api/v1/domains
X-Tenant-ID: {tenant-uuid}

Response 200:
{
  "domains": [
    {
      "id": "uuid",
      "domain": "store.example.com",
      "status": "active",
      "dns_verified": true,
      "ssl_status": "active",
      "primary_domain": true
    }
  ],
  "total": 1,
  "limit": 5
}
```

#### Verify Domain
```http
POST /api/v1/domains/{id}/verify
X-Tenant-ID: {tenant-uuid}

Response 200:
{
  "verified": true,
  "message": "DNS verification successful"
}
```

#### Set Primary Domain
```http
PATCH /api/v1/domains/{id}
X-Tenant-ID: {tenant-uuid}

{
  "primary_domain": true
}

Response 200:
{
  "id": "uuid",
  "domain": "store.example.com",
  "primary_domain": true
}
```

#### Delete Domain
```http
DELETE /api/v1/domains/{id}
X-Tenant-ID: {tenant-uuid}

Response 200:
{
  "success": true,
  "message": "Domain deleted and resources cleaned up"
}
```

### Internal APIs

#### Resolve Domain (Service-to-Service)
```http
GET /api/v1/internal/resolve?domain=store.example.com

Response 200:
{
  "tenant_id": "tenant-uuid",
  "tenant_slug": "awesome-store",
  "target_type": "storefront",
  "is_active": true
}
```

---

## Configuration

### Environment Variables

#### Custom Domain Service
```yaml
# Database
DATABASE_HOST: "postgresql.postgresql-marketplace.svc.cluster.local"
DATABASE_PORT: "5432"
DATABASE_NAME: "custom_domains_db"
DATABASE_SSLMODE: "require"

# Redis (caching)
REDIS_HOST: "redis.redis-marketplace.svc.cluster.local"
REDIS_PORT: "6379"

# Tenant Service
TENANT_SERVICE_URL: "http://tenant-service.marketplace.svc.cluster.local:8080"

# DNS Configuration
DNS_PROXY_DOMAIN: "proxy.tesserix.app"
DNS_VERIFICATION_INTERVAL: "5m"

# SSL Configuration
SSL_ISSUER_NAME: "letsencrypt-prod"
SSL_ISSUER_KIND: "ClusterIssuer"
SSL_CERTIFICATE_NAMESPACE: "istio-ingress"

# Keycloak
KEYCLOAK_ADMIN_URL: "https://identity.tesserix.app"
KEYCLOAK_REALM: "tesserix-customer"

# Limits
MAX_DOMAINS_PER_TENANT: "5"

# CORS
CORS_ALLOWED_ORIGINS: "https://admin.tesserix.app,https://onboarding.tesserix.app"
```

#### Storefront
```yaml
# Tenant Resolution
TENANT_ROUTER_SERVICE_URL: "http://tenant-router-service.marketplace.svc.cluster.local:8089"
CUSTOM_DOMAIN_SERVICE_URL: "http://custom-domain-service.marketplace.svc.cluster.local:8093"
```

---

## Troubleshooting

### Common Issues

#### Domain stuck in "pending" status

**Cause**: DNS verification failing

**Solution**:
1. Check DNS propagation: `dig TXT _tesserix.store.example.com`
2. Verify CNAME points to `proxy.tesserix.app`
3. Wait for DNS propagation (up to 24 hours for some registrars)
4. Check custom-domain-service logs for verification errors

#### SSL certificate not provisioning

**Cause**: cert-manager unable to validate domain

**Solution**:
1. Check Certificate resource: `kubectl get certificate -n istio-ingress`
2. Check cert-manager logs: `kubectl logs -n cert-manager deploy/cert-manager`
3. Verify DNS is resolving to correct IP
4. Check ACME challenge completion

#### Custom domain returns 404

**Cause**: VirtualService not created or Gateway not patched

**Solution**:
1. Check VirtualService exists: `kubectl get vs -n istio-config | grep store-example-com`
2. Check Gateway configuration: `kubectl get gateway -n istio-ingress tesseract-gateway -o yaml`
3. Verify domain in Gateway HTTPS server hosts list

#### Storefront shows wrong tenant

**Cause**: Header injection not working

**Solution**:
1. Check VirtualService headers configuration
2. Verify x-tenant-id header in request: `curl -v https://store.example.com`
3. Check storefront logs for resolution method used

### Useful Commands

```bash
# Check domain status in database
kubectl exec -n marketplace deploy/custom-domain-service -- \
  psql -U postgres -d custom_domains_db -c \
  "SELECT domain, status, dns_verified, ssl_status FROM custom_domains;"

# Check VirtualService for custom domain
kubectl get vs -n istio-config -o yaml | grep -A 20 "store-example-com"

# Check certificate status
kubectl get certificate -n istio-ingress

# Force DNS verification
curl -X POST https://admin.tesserix.app/api/domains/{id}?action=verify

# Check Gateway hosts
kubectl get gateway -n istio-ingress tesseract-gateway -o jsonpath='{.spec.servers[*].hosts}'
```

---

## Summary

| Aspect | Built-in Domain | Custom Domain (HTTP-01) | Custom Domain (NS Delegation) |
|--------|-----------------|-------------------------|-------------------------------|
| **Setup Time** | Instant | 5-30 minutes | 5-10 minutes |
| **DNS Required** | No | CNAME + TXT | NS + CNAME |
| **SSL Certificate** | Wildcard (shared) | Individual (HTTP-01) | Individual (DNS-01) |
| **Renewal** | Automatic | Depends on routing | Always works |
| **Wildcard Support** | N/A | No | Yes |
| **Managed By** | Tenant Router Service | Custom Domain Service | Custom Domain Service |
| **Recommended** | Quick start | Legacy support | **Production use** |

**Key Principles**:
1. Built-in domain is always provisioned first (instant availability)
2. Custom domains are additive, not replacements
3. Both domains work in parallel during migration
4. User explicitly sets primary domain
5. Old domain can optionally redirect to new
6. Cleanup is automated with configurable retention
7. **NS Delegation is the recommended approach** for custom domains (automatic renewals, no HTTP dependency)

### Certificate Method Selection

```
┌─────────────────────────────────────────────────────────────────┐
│                    CERTIFICATE METHOD PRIORITY                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. NS Delegation Verified?                                      │
│     YES → DNS-01 via Cloud DNS (letsencrypt-prod-ns-delegation) │
│                                                                  │
│  2. Cloudflare Tunnel Enabled?                                   │
│     YES → Edge SSL (no cert-manager certificate needed)          │
│                                                                  │
│  3. Fallback                                                     │
│     → HTTP-01 via Istio (letsencrypt-prod-http01)               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```
