-- tenant_router_db schema
-- Managed by db-schema-bootstrap CronJob (idempotent)

CREATE TABLE IF NOT EXISTS tenant_hosts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    slug varchar(63) NOT NULL,
    admin_host varchar(255) NOT NULL,
    storefront_host varchar(255) NOT NULL,
    storefront_www_host varchar(255),
    api_host varchar(255),
    status varchar(20) NOT NULL DEFAULT 'pending',
    is_custom_domain boolean DEFAULT false,
    product varchar(50) DEFAULT 'marketplace',
    business_name varchar(255),
    email varchar(255),
    dns_configured boolean DEFAULT false,
    ssl_active boolean DEFAULT false,
    service_routed boolean DEFAULT false,
    error_message text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_hosts_tenant_id ON tenant_hosts (tenant_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_hosts_slug ON tenant_hosts (slug);
CREATE INDEX IF NOT EXISTS idx_tenant_hosts_deleted_at ON tenant_hosts (deleted_at);

CREATE TABLE IF NOT EXISTS custom_domains (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    domain varchar(255) NOT NULL,
    target_type varchar(20) NOT NULL DEFAULT 'storefront',
    status varchar(20) NOT NULL DEFAULT 'pending',
    verification_token varchar(255),
    verification_host varchar(255),
    verification_value varchar(255),
    dns_verified boolean DEFAULT false,
    ssl_status varchar(20) DEFAULT 'pending',
    routing_status varchar(20) DEFAULT 'pending',
    cloudflare_dns_id varchar(100),
    redirect_www boolean DEFAULT true,
    force_https boolean DEFAULT true,
    is_primary boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone
);

CREATE INDEX IF NOT EXISTS idx_custom_domains_tenant_id ON custom_domains (tenant_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_custom_domains_domain ON custom_domains (domain);
CREATE INDEX IF NOT EXISTS idx_custom_domains_deleted_at ON custom_domains (deleted_at);
