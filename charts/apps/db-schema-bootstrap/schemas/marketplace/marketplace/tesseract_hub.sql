--
-- PostgreSQL database dump
--


-- Dumped from database version 16.11
-- Dumped by pg_dump version 16.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: location; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS location;


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: address_cache_updated_at(); Type: FUNCTION; Schema: location; Owner: -
--

CREATE OR REPLACE FUNCTION location.address_cache_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;


--
-- Name: generate_geohash(numeric, numeric, integer); Type: FUNCTION; Schema: location; Owner: -
--

CREATE OR REPLACE FUNCTION location.generate_geohash(lat numeric, lng numeric, hash_length integer DEFAULT 6) RETURNS character varying
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    base32_chars VARCHAR := '0123456789bcdefghjkmnpqrstuvwxyz';
    geohash VARCHAR := '';
    min_lat DECIMAL := -90.0;
    max_lat DECIMAL := 90.0;
    min_lng DECIMAL := -180.0;
    max_lng DECIMAL := 180.0;
    mid DECIMAL;
    bit INT := 0;
    ch INT := 0;
    is_lng BOOLEAN := true;
BEGIN
    WHILE length(geohash) < hash_length LOOP
        IF is_lng THEN
            mid := (min_lng + max_lng) / 2;
            IF lng >= mid THEN
                ch := ch | (16 >> bit);
                min_lng := mid;
            ELSE
                max_lng := mid;
            END IF;
        ELSE
            mid := (min_lat + max_lat) / 2;
            IF lat >= mid THEN
                ch := ch | (16 >> bit);
                min_lat := mid;
            ELSE
                max_lat := mid;
            END IF;
        END IF;

        is_lng := NOT is_lng;
        bit := bit + 1;

        IF bit = 5 THEN
            geohash := geohash || substr(base32_chars, ch + 1, 1);
            bit := 0;
            ch := 0;
        END IF;
    END LOOP;

    RETURN geohash;
END;
$$;


--
-- Name: places_geohash_update(); Type: FUNCTION; Schema: location; Owner: -
--

CREATE OR REPLACE FUNCTION location.places_geohash_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL THEN
        NEW.geohash := generate_geohash(NEW.latitude, NEW.longitude, 8);
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: places_search_vector_update(); Type: FUNCTION; Schema: location; Owner: -
--

CREATE OR REPLACE FUNCTION location.places_search_vector_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.search_vector := to_tsvector('english',
        COALESCE(NEW.formatted_address, '') || ' ' ||
        COALESCE(NEW.street_name, '') || ' ' ||
        COALESCE(NEW.city, '') || ' ' ||
        COALESCE(NEW.district, '') || ' ' ||
        COALESCE(NEW.state_name, '') || ' ' ||
        COALESCE(NEW.country_name, '') || ' ' ||
        COALESCE(NEW.postal_code, '')
    );
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: address_cache; Type: TABLE; Schema: location; Owner: -
--

CREATE TABLE IF NOT EXISTS location.address_cache (
    id bigint NOT NULL,
    cache_type character varying(20) NOT NULL,
    cache_key_hash character varying(64) NOT NULL,
    cache_key text NOT NULL,
    formatted_address text,
    place_id character varying(500),
    latitude numeric(10,8),
    longitude numeric(11,8),
    street_number character varying(50),
    street_name character varying(255),
    city character varying(255),
    district character varying(255),
    state_code character varying(10),
    state_name character varying(255),
    country_code character varying(2),
    country_name character varying(100),
    postal_code character varying(20),
    response_json jsonb,
    provider character varying(50) NOT NULL,
    hit_count integer DEFAULT 0,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE address_cache; Type: COMMENT; Schema: location; Owner: -
--

COMMENT ON TABLE location.address_cache IS 'Cache for address lookup operations (geocode, reverse geocode, autocomplete)';


--
-- Name: COLUMN address_cache.cache_type; Type: COMMENT; Schema: location; Owner: -
--

COMMENT ON COLUMN location.address_cache.cache_type IS 'Type: geocode, reverse, autocomplete, place_details';


--
-- Name: COLUMN address_cache.cache_key_hash; Type: COMMENT; Schema: location; Owner: -
--

COMMENT ON COLUMN location.address_cache.cache_key_hash IS 'SHA256 hash of normalized query for fast lookups';


--
-- Name: COLUMN address_cache.hit_count; Type: COMMENT; Schema: location; Owner: -
--

COMMENT ON COLUMN location.address_cache.hit_count IS 'Number of times this cache entry has been accessed';


--
-- Name: address_cache_id_seq; Type: SEQUENCE; Schema: location; Owner: -
--

CREATE SEQUENCE IF NOT EXISTS location.address_cache_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: address_cache_id_seq; Type: SEQUENCE OWNED BY; Schema: location; Owner: -
--

ALTER SEQUENCE location.address_cache_id_seq OWNED BY location.address_cache.id;


--
-- Name: countries; Type: TABLE; Schema: location; Owner: -
--

CREATE TABLE IF NOT EXISTS location.countries (
    id character varying(2) NOT NULL,
    name character varying(100) NOT NULL,
    native_name character varying(100),
    capital character varying(100),
    region character varying(50),
    subregion character varying(50),
    currency character varying(3),
    languages text,
    calling_code character varying(10),
    flag_emoji character varying(10),
    latitude numeric(10,6),
    longitude numeric(10,6),
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone
);


--
-- Name: currencies; Type: TABLE; Schema: location; Owner: -
--

CREATE TABLE IF NOT EXISTS location.currencies (
    code character varying(3) NOT NULL,
    name character varying(100) NOT NULL,
    symbol character varying(10) NOT NULL,
    decimal_places integer DEFAULT 2,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone
);


--
-- Name: location_cache; Type: TABLE; Schema: location; Owner: -
--

CREATE TABLE IF NOT EXISTS location.location_cache (
    id bigint NOT NULL,
    ip character varying(45) NOT NULL,
    country_id character varying(2),
    state_id character varying(10),
    city character varying(100),
    postal_code character varying(20),
    latitude numeric(10,6),
    longitude numeric(10,6),
    timezone_id character varying(50),
    isp character varying(200),
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: location_cache_id_seq; Type: SEQUENCE; Schema: location; Owner: -
--

CREATE SEQUENCE IF NOT EXISTS location.location_cache_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: location_cache_id_seq; Type: SEQUENCE OWNED BY; Schema: location; Owner: -
--

ALTER SEQUENCE location.location_cache_id_seq OWNED BY location.location_cache.id;


--
-- Name: places; Type: TABLE; Schema: location; Owner: -
--

CREATE TABLE IF NOT EXISTS location.places (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    external_place_id character varying(500),
    formatted_address text NOT NULL,
    latitude numeric(10,8) NOT NULL,
    longitude numeric(11,8) NOT NULL,
    geohash character varying(12),
    street_number character varying(50),
    street_name character varying(255),
    city character varying(255),
    district character varying(255),
    state_code character varying(10),
    state_name character varying(255),
    country_code character varying(2),
    country_name character varying(100),
    postal_code character varying(20),
    place_types text[],
    source_provider character varying(50),
    confidence numeric(3,2),
    verified boolean DEFAULT false,
    search_vector tsvector,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone
);


--
-- Name: TABLE places; Type: COMMENT; Schema: location; Owner: -
--

COMMENT ON TABLE location.places IS 'Permanent storage of geocoded places for internal GeoTag API';


--
-- Name: COLUMN places.geohash; Type: COMMENT; Schema: location; Owner: -
--

COMMENT ON COLUMN location.places.geohash IS 'Geohash for efficient nearby queries (8 chars = ~38m precision)';


--
-- Name: COLUMN places.confidence; Type: COMMENT; Schema: location; Owner: -
--

COMMENT ON COLUMN location.places.confidence IS 'Geocoding confidence score from 0.00 to 1.00';


--
-- Name: COLUMN places.verified; Type: COMMENT; Schema: location; Owner: -
--

COMMENT ON COLUMN location.places.verified IS 'Whether address has been manually verified';


--
-- Name: schema_migrations; Type: TABLE; Schema: location; Owner: -
--

CREATE TABLE IF NOT EXISTS location.schema_migrations (
    version bigint NOT NULL,
    dirty boolean DEFAULT false,
    applied_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: states; Type: TABLE; Schema: location; Owner: -
--

CREATE TABLE IF NOT EXISTS location.states (
    id character varying(10) NOT NULL,
    name character varying(100) NOT NULL,
    native_name character varying(100),
    code character varying(10) NOT NULL,
    country_id character varying(2) NOT NULL,
    type character varying(20) DEFAULT 'state'::character varying,
    latitude numeric(10,6),
    longitude numeric(10,6),
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone
);


--
-- Name: timezones; Type: TABLE; Schema: location; Owner: -
--

CREATE TABLE IF NOT EXISTS location.timezones (
    id character varying(50) NOT NULL,
    name character varying(100) NOT NULL,
    abbreviation character varying(10),
    "offset" character varying(10) NOT NULL,
    dst boolean DEFAULT false,
    countries text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone
);


--
-- Name: ad_billing_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.ad_billing_invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id uuid NOT NULL,
    invoice_number character varying(50) NOT NULL,
    period_start timestamp with time zone NOT NULL,
    period_end timestamp with time zone NOT NULL,
    status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    total_spend numeric(12,2) NOT NULL,
    commission_rate numeric(5,4) NOT NULL,
    commission_amount numeric(12,2) NOT NULL,
    tax_amount numeric(12,2) DEFAULT 0,
    total_due numeric(12,2) NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    due_date timestamp with time zone NOT NULL,
    paid_at timestamp with time zone,
    payment_transaction_id uuid,
    line_items jsonb,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: ad_campaign_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.ad_campaign_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    payment_type character varying(20) NOT NULL,
    status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    budget_amount numeric(12,2) NOT NULL,
    commission_rate numeric(5,4),
    commission_amount numeric(12,2) DEFAULT 0,
    tax_amount numeric(12,2) DEFAULT 0,
    total_amount numeric(12,2) NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    commission_tier_id uuid,
    campaign_days bigint,
    payment_transaction_id uuid,
    gateway_type character varying(50),
    gateway_transaction_id character varying(255),
    paid_at timestamp with time zone,
    refunded_at timestamp with time zone,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: ad_commission_tiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.ad_commission_tiers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    name character varying(100) NOT NULL,
    min_days bigint NOT NULL,
    max_days bigint,
    commission_rate numeric(5,4) NOT NULL,
    tax_inclusive boolean DEFAULT true,
    is_active boolean DEFAULT true,
    priority bigint DEFAULT 0,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: ad_revenue_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.ad_revenue_ledger (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    entry_type character varying(30) NOT NULL,
    amount numeric(12,2) NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    balance_after numeric(12,2) NOT NULL,
    campaign_payment_id uuid,
    invoice_id uuid,
    payment_transaction_id uuid,
    description text,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: ad_vendor_balances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.ad_vendor_balances (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id uuid NOT NULL,
    current_balance numeric(12,2) DEFAULT 0 NOT NULL,
    total_deposited numeric(12,2) DEFAULT 0 NOT NULL,
    total_spent numeric(12,2) DEFAULT 0 NOT NULL,
    total_refunded numeric(12,2) DEFAULT 0 NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: application_configurations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.application_configurations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    application_type text NOT NULL,
    configuration_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: business_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.business_addresses (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    address_type text DEFAULT 'business'::text,
    street_address text NOT NULL,
    city text NOT NULL,
    state_province text NOT NULL,
    postal_code text NOT NULL,
    country text NOT NULL,
    is_primary boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: business_informations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.business_informations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    business_name text NOT NULL,
    business_type text NOT NULL,
    industry text NOT NULL,
    business_description text,
    website text,
    registration_number text,
    tax_id text,
    incorporation_date timestamp with time zone,
    employee_count text,
    annual_revenue text,
    is_verified boolean DEFAULT false,
    verification_documents jsonb DEFAULT '[]'::jsonb,
    tenant_slug character varying(50),
    storefront_slug character varying(50),
    business_model character varying(50) DEFAULT 'ONLINE_STORE'::character varying,
    existing_store_platforms jsonb DEFAULT '[]'::jsonb,
    has_existing_store boolean DEFAULT false,
    migration_interest boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: contact_informations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.contact_informations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    first_name text NOT NULL,
    last_name text NOT NULL,
    email text NOT NULL,
    phone text NOT NULL,
    phone_country_code character varying(10) DEFAULT ''::character varying,
    job_title text,
    is_primary_contact boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: deactivated_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.deactivated_memberships (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    original_membership_id uuid NOT NULL,
    user_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    email character varying(255) NOT NULL,
    first_name character varying(100),
    last_name character varying(100),
    membership_data jsonb DEFAULT '{}'::jsonb,
    deactivation_reason text,
    deactivated_at timestamp with time zone NOT NULL,
    scheduled_purge_at timestamp with time zone NOT NULL,
    reactivated_at timestamp with time zone,
    reactivation_count bigint DEFAULT 0,
    is_purged boolean DEFAULT false,
    purged_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: deleted_tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.deleted_tenants (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    original_tenant_id uuid NOT NULL,
    slug character varying(100) NOT NULL,
    business_name character varying(255) NOT NULL,
    owner_user_id uuid NOT NULL,
    owner_email character varying(255) NOT NULL,
    tenant_data jsonb NOT NULL,
    memberships_data jsonb DEFAULT '[]'::jsonb,
    vendors_data jsonb DEFAULT '[]'::jsonb,
    storefronts_data jsonb DEFAULT '[]'::jsonb,
    deleted_by_user_id uuid NOT NULL,
    deletion_reason text,
    deleted_at timestamp with time zone,
    resources_cleaned jsonb DEFAULT '{}'::jsonb,
    cleanup_completed_at timestamp with time zone
);


--
-- Name: domain_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.domain_reservations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    domain_type text NOT NULL,
    domain_value text NOT NULL,
    status text DEFAULT 'reserved'::text,
    verification_method text,
    verification_token text,
    verified_at timestamp with time zone,
    expires_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: gateway_customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.gateway_customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    customer_id uuid NOT NULL,
    gateway_type character varying(50) NOT NULL,
    gateway_customer_id character varying(255) NOT NULL,
    email character varying(255),
    name character varying(255),
    phone character varying(50),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: marketplace_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.marketplace_connections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255) NOT NULL,
    marketplace_type character varying(50) NOT NULL,
    display_name character varying(255) NOT NULL,
    status character varying(50) DEFAULT 'PENDING'::character varying NOT NULL,
    is_enabled boolean DEFAULT true,
    external_store_id character varying(255),
    external_store_url character varying(500),
    secret_reference character varying(500),
    token_expires_at timestamp with time zone,
    config jsonb DEFAULT '{}'::jsonb,
    sync_settings jsonb DEFAULT '{"sync_orders": true, "sync_products": true, "sync_inventory": true, "auto_sync_enabled": false, "sync_interval_minutes": 60}'::jsonb,
    last_sync_at timestamp with time zone,
    last_error text,
    error_count bigint DEFAULT 0,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(255)
);


--
-- Name: marketplace_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.marketplace_credentials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid NOT NULL,
    gcp_secret_name character varying(500) NOT NULL,
    gcp_secret_version character varying(50) DEFAULT 'latest'::character varying,
    credential_type character varying(50) NOT NULL,
    scopes text[],
    issued_at timestamp with time zone,
    expires_at timestamp with time zone,
    refresh_scheduled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: marketplace_inventory_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.marketplace_inventory_mappings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    internal_product_id uuid NOT NULL,
    internal_variant_id uuid,
    internal_sku character varying(255) NOT NULL,
    external_sku character varying(255) NOT NULL,
    external_location_id character varying(255),
    last_known_quantity bigint DEFAULT 0,
    last_quantity_synced_at timestamp with time zone,
    sync_status character varying(50) DEFAULT 'SYNCED'::character varying,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: marketplace_order_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.marketplace_order_mappings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    internal_order_id uuid NOT NULL,
    external_order_id character varying(255) NOT NULL,
    external_order_number character varying(100),
    sync_status character varying(50) DEFAULT 'SYNCED'::character varying,
    last_synced_at timestamp with time zone,
    marketplace_status character varying(100),
    marketplace_created_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: marketplace_product_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.marketplace_product_mappings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    internal_product_id uuid NOT NULL,
    internal_variant_id uuid,
    external_product_id character varying(255) NOT NULL,
    external_variant_id character varying(255),
    external_sku character varying(255),
    sync_status character varying(50) DEFAULT 'SYNCED'::character varying,
    last_synced_at timestamp with time zone,
    last_sync_direction character varying(20),
    internal_version bigint DEFAULT 1,
    external_version character varying(100),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: marketplace_sync_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.marketplace_sync_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    job_type character varying(50) DEFAULT 'FULL_IMPORT'::character varying,
    sync_type character varying(50) NOT NULL,
    direction character varying(50) DEFAULT 'INBOUND'::character varying NOT NULL,
    status character varying(50) DEFAULT 'PENDING'::character varying NOT NULL,
    progress jsonb DEFAULT '{"percentage": 0, "totalItems": 0, "failedItems": 0, "skippedItems": 0, "processedItems": 0, "successfulItems": 0}'::jsonb,
    cursor_position jsonb,
    idempotency_key character varying(255),
    parent_job_id uuid,
    priority bigint DEFAULT 5,
    scheduled_at timestamp with time zone,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    error_message text,
    error_details jsonb,
    retry_count bigint DEFAULT 0,
    max_retries bigint DEFAULT 3,
    triggered_by character varying(50),
    created_by character varying(255),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: marketplace_sync_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.marketplace_sync_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    sync_job_id uuid NOT NULL,
    level character varying(20) DEFAULT 'info'::character varying NOT NULL,
    message text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: marketplace_webhook_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.marketplace_webhook_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid,
    tenant_id character varying(255),
    marketplace_type character varying(50) NOT NULL,
    event_id character varying(255) NOT NULL,
    event_type character varying(100) NOT NULL,
    payload jsonb NOT NULL,
    headers jsonb,
    processed boolean DEFAULT false,
    processed_at timestamp with time zone,
    processing_error text,
    retry_count bigint DEFAULT 0,
    idempotency_key character varying(255),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: onboarding_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.onboarding_notifications (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    notification_type text NOT NULL,
    template_name text NOT NULL,
    recipient text NOT NULL,
    subject text,
    content text,
    status text DEFAULT 'pending'::text,
    provider text,
    provider_message_id text,
    sent_at timestamp with time zone,
    delivered_at timestamp with time zone,
    error_message text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone
);


--
-- Name: onboarding_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.onboarding_sessions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id uuid,
    template_id uuid NOT NULL,
    application_type text NOT NULL,
    status text DEFAULT 'started'::text,
    current_step text,
    progress_percentage bigint DEFAULT 0,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    expires_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    business_model character varying(50) DEFAULT 'ONLINE_STORE'::character varying,
    draft_saved_at timestamp with time zone,
    draft_expires_at timestamp with time zone,
    reminder_count bigint DEFAULT 0,
    last_reminder_at timestamp with time zone,
    browser_closed_at timestamp with time zone,
    draft_form_data jsonb DEFAULT '{}'::jsonb
);


--
-- Name: onboarding_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.onboarding_tasks (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    task_id text NOT NULL,
    name text NOT NULL,
    description text,
    task_type text NOT NULL,
    status text DEFAULT 'pending'::text,
    is_required boolean DEFAULT true,
    order_index bigint NOT NULL,
    estimated_duration_mins bigint,
    dependencies jsonb DEFAULT '[]'::jsonb,
    completion_data jsonb DEFAULT '{}'::jsonb,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    skipped_at timestamp with time zone,
    skip_reason text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: onboarding_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.onboarding_templates (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name text NOT NULL,
    description text,
    application_type text NOT NULL,
    version bigint DEFAULT 1,
    is_active boolean DEFAULT true,
    is_default boolean DEFAULT false,
    template_config jsonb DEFAULT '{}'::jsonb,
    steps jsonb DEFAULT '[]'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: password_reset_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.password_reset_tokens (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    token character varying(255) NOT NULL,
    user_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    email character varying(255) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    is_used boolean DEFAULT false,
    requested_ip character varying(45),
    requested_agent text,
    used_ip character varying(45),
    used_agent text,
    created_at timestamp with time zone
);


--
-- Name: payment_disputes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.payment_disputes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    payment_transaction_id uuid NOT NULL,
    gateway_dispute_id character varying(255) NOT NULL,
    amount numeric(12,2) NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    reason character varying(100),
    status character varying(50) NOT NULL,
    evidence jsonb,
    evidence_submitted_at timestamp with time zone,
    respond_by timestamp with time zone,
    resolved_at timestamp with time zone,
    resolution character varying(50),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: payment_gateway_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.payment_gateway_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    gateway_type character varying(50) NOT NULL,
    display_name character varying(255) NOT NULL,
    is_enabled boolean DEFAULT true,
    is_test_mode boolean DEFAULT true,
    api_key_public text,
    api_key_secret text,
    webhook_secret text,
    config jsonb,
    supports_payments boolean DEFAULT true,
    supports_refunds boolean DEFAULT true,
    supports_subscriptions boolean DEFAULT false,
    merchant_account_id character varying(255),
    platform_account_id character varying(255),
    supports_platform_split boolean DEFAULT false,
    supported_countries text[],
    supported_payment_methods text[],
    fee_structure jsonb DEFAULT '{"fixed_fee": 0, "percent_fee": 0}'::jsonb,
    minimum_amount numeric(10,2),
    maximum_amount numeric(10,2),
    priority bigint DEFAULT 0,
    description text,
    logo_url character varying(500),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: payment_gateway_regions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.payment_gateway_regions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    gateway_config_id uuid NOT NULL,
    country_code character varying(2) NOT NULL,
    is_primary boolean DEFAULT false,
    priority bigint DEFAULT 0,
    enabled boolean DEFAULT true,
    supported_methods text[],
    min_amount numeric(10,2),
    max_amount numeric(10,2),
    currency character varying(3),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: payment_gateway_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.payment_gateway_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    gateway_type character varying(50) NOT NULL,
    display_name character varying(255) NOT NULL,
    description text,
    logo_url character varying(500),
    supports_payments boolean DEFAULT true,
    supports_refunds boolean DEFAULT true,
    supports_subscriptions boolean DEFAULT false,
    supports_platform_split boolean DEFAULT false,
    supported_countries text[] NOT NULL,
    supported_payment_methods text[] NOT NULL,
    default_config jsonb,
    required_credentials text[] DEFAULT '{api_key_public,api_key_secret}'::text[],
    setup_instructions text,
    documentation_url character varying(500),
    priority bigint DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: payment_informations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.payment_informations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    subscription_plan text,
    billing_cycle text,
    payment_method text,
    payment_provider text,
    payment_provider_customer_id text,
    payment_provider_subscription_id text,
    trial_end_date timestamp with time zone,
    billing_address jsonb,
    payment_status text DEFAULT 'pending'::text,
    setup_intent_id text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: payment_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.payment_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    default_currency character varying(3) DEFAULT 'USD'::character varying,
    supported_currencies character varying(3)[],
    platform_fee_enabled boolean DEFAULT true,
    platform_fee_percent numeric(5,4) DEFAULT 0.05,
    platform_account_id character varying(255),
    fee_payer character varying(20) DEFAULT 'merchant'::character varying,
    minimum_platform_fee numeric(10,2) DEFAULT 0,
    maximum_platform_fee numeric(10,2),
    enable_express_checkout boolean DEFAULT true,
    collect_billing_address boolean DEFAULT true,
    collect_shipping_address boolean DEFAULT true,
    enable3_d_secure boolean DEFAULT true,
    require3_d_secure_for_amounts_above numeric(10,2),
    enable_fraud_detection boolean DEFAULT true,
    auto_cancel_risky_payments boolean DEFAULT false,
    max_payment_retry_attempts bigint DEFAULT 3,
    send_payment_receipts boolean DEFAULT true,
    send_refund_notifications boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: payment_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.payment_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    order_id uuid NOT NULL,
    customer_id uuid,
    gateway_config_id uuid NOT NULL,
    gateway_type character varying(50) NOT NULL,
    gateway_transaction_id character varying(255),
    amount numeric(12,2) NOT NULL,
    gross_amount numeric(12,2),
    platform_fee numeric(12,2) DEFAULT 0,
    platform_fee_percent numeric(5,4) DEFAULT 0.05,
    gateway_fee numeric(12,2) DEFAULT 0,
    gateway_tax numeric(12,2) DEFAULT 0,
    net_amount numeric(12,2),
    currency character varying(3) DEFAULT 'USD'::character varying,
    idempotency_key character varying(255),
    retry_count bigint DEFAULT 0,
    last_retry_at timestamp with time zone,
    country_code character varying(2),
    status character varying(50) NOT NULL,
    payment_method_type character varying(50),
    card_brand character varying(50),
    card_last_four character varying(4),
    card_exp_month bigint,
    card_exp_year bigint,
    billing_email character varying(255),
    billing_name character varying(255),
    billing_address jsonb,
    processed_at timestamp with time zone,
    failed_at timestamp with time zone,
    failure_code character varying(100),
    failure_message text,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: payment_webhook_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.payment_webhook_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255),
    gateway_type character varying(50) NOT NULL,
    event_id character varying(255) NOT NULL,
    event_type character varying(100) NOT NULL,
    payload jsonb NOT NULL,
    processed boolean DEFAULT false,
    processed_at timestamp with time zone,
    processing_error text,
    retry_count bigint DEFAULT 0,
    payment_transaction_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: platform_fee_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.platform_fee_ledger (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    payment_transaction_id uuid,
    refund_transaction_id uuid,
    entry_type character varying(20) NOT NULL,
    amount numeric(12,2) NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    status character varying(20) DEFAULT 'pending'::character varying,
    gateway_type character varying(50),
    gateway_transfer_id character varying(255),
    gateway_payout_id character varying(255),
    settled_at timestamp with time zone,
    settlement_batch_id character varying(255),
    error_code character varying(100),
    error_message text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: provisioning_activity_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.provisioning_activity_logs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_host_id uuid NOT NULL,
    action character varying(100) NOT NULL,
    resource character varying(100),
    namespace character varying(255),
    success boolean DEFAULT false,
    error_message text,
    duration bigint DEFAULT 0,
    created_at timestamp with time zone
);


--
-- Name: rate_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.rate_limits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    identifier character varying(255) NOT NULL,
    type character varying(20) NOT NULL,
    count bigint DEFAULT 0,
    window_start timestamp with time zone NOT NULL,
    window_end timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: refund_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.refund_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    payment_transaction_id uuid NOT NULL,
    gateway_refund_id character varying(255),
    amount numeric(12,2) NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    platform_fee_refund numeric(12,2) DEFAULT 0,
    gateway_fee_refund numeric(12,2) DEFAULT 0,
    net_refund_amount numeric(12,2),
    refund_type character varying(20) DEFAULT 'full'::character varying,
    status character varying(50) NOT NULL,
    reason character varying(255),
    processed_at timestamp with time zone,
    failed_at timestamp with time zone,
    failure_code character varying(100),
    failure_message text,
    metadata jsonb,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: reserved_slugs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.reserved_slugs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    slug character varying(50) NOT NULL,
    reason character varying(255) NOT NULL,
    category character varying(50) DEFAULT 'system'::character varying NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    created_by character varying(255),
    updated_at timestamp with time zone
);


--
-- Name: saved_payment_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.saved_payment_methods (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    customer_id uuid NOT NULL,
    gateway_config_id uuid NOT NULL,
    gateway_type character varying(50) NOT NULL,
    gateway_payment_method_id character varying(255) NOT NULL,
    payment_method_type character varying(50) NOT NULL,
    card_brand character varying(50),
    card_last_four character varying(4),
    card_exp_month bigint,
    card_exp_year bigint,
    bank_name character varying(255),
    account_last_four character varying(4),
    pay_pal_email character varying(255),
    is_default boolean DEFAULT false,
    is_active boolean DEFAULT true,
    billing_name character varying(255),
    billing_email character varying(255),
    billing_address jsonb,
    is_verified boolean DEFAULT false,
    verified_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version bigint NOT NULL,
    dirty boolean DEFAULT false,
    applied_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: secret_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.secret_audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    secret_name character varying(255) NOT NULL,
    category character varying(50) NOT NULL,
    provider character varying(50) NOT NULL,
    action character varying(50) NOT NULL,
    status character varying(20) NOT NULL,
    error_message text,
    actor_id character varying(100),
    actor_service character varying(100),
    request_id character varying(100),
    ip_address character varying(50),
    metadata jsonb,
    created_at timestamp with time zone
);


--
-- Name: secret_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.secret_metadata (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    category character varying(50) NOT NULL,
    scope character varying(20) NOT NULL,
    scope_id character varying(100),
    provider character varying(50) NOT NULL,
    key_name character varying(100) NOT NULL,
    gcp_secret_name character varying(255) NOT NULL,
    gcp_secret_version character varying(50),
    configured boolean DEFAULT true NOT NULL,
    validation_status character varying(20) DEFAULT 'UNKNOWN'::character varying,
    validation_message text,
    last_updated_by character varying(100),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: shipment_trackings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.shipment_trackings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    shipment_id uuid NOT NULL,
    status character varying(100) NOT NULL,
    location character varying(255),
    description text,
    "timestamp" timestamp with time zone NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: shipments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.shipments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    order_id uuid NOT NULL,
    order_number character varying(100),
    carrier character varying(50) NOT NULL,
    carrier_shipment_id character varying(255),
    tracking_number character varying(255),
    tracking_url character varying(500),
    label_url character varying(500),
    status character varying(50) DEFAULT 'PENDING'::character varying NOT NULL,
    from_name character varying(255),
    from_company character varying(255),
    from_phone character varying(50),
    from_email character varying(255),
    from_street character varying(500),
    from_street2 character varying(500),
    from_city character varying(100),
    from_state character varying(100),
    from_postal_code character varying(20),
    from_country character varying(10),
    to_name character varying(255),
    to_company character varying(255),
    to_phone character varying(50),
    to_email character varying(255),
    to_street character varying(500),
    to_street2 character varying(500),
    to_city character varying(100),
    to_state character varying(100),
    to_postal_code character varying(20),
    to_country character varying(10),
    weight numeric(10,2),
    length numeric(10,2),
    width numeric(10,2),
    height numeric(10,2),
    shipping_cost numeric(10,2),
    currency character varying(10) DEFAULT 'USD'::character varying,
    estimated_delivery timestamp with time zone,
    actual_delivery timestamp with time zone,
    pickup_scheduled timestamp with time zone,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: shipping_carrier_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.shipping_carrier_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    carrier_type character varying(50) NOT NULL,
    display_name character varying(255) NOT NULL,
    is_enabled boolean DEFAULT true,
    is_test_mode boolean DEFAULT true,
    api_key_public text,
    api_key_secret text,
    webhook_secret text,
    base_url text,
    credentials jsonb,
    config jsonb,
    supports_rates boolean DEFAULT true,
    supports_tracking boolean DEFAULT true,
    supports_labels boolean DEFAULT true,
    supports_returns boolean DEFAULT false,
    supports_pickup boolean DEFAULT false,
    supported_countries text[],
    supported_services text[],
    max_weight numeric(10,2),
    max_length numeric(10,2),
    max_volume numeric(10,2),
    priority bigint DEFAULT 0,
    description text,
    logo_url character varying(500),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    credentials_provisioned boolean DEFAULT false,
    credential_provider character varying(50) DEFAULT 'database'::character varying
);


--
-- Name: shipping_carrier_regions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.shipping_carrier_regions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    carrier_config_id uuid NOT NULL,
    country_code character varying(2) NOT NULL,
    is_primary boolean DEFAULT false,
    priority bigint DEFAULT 0,
    enabled boolean DEFAULT true,
    supported_services text[],
    default_service character varying(100),
    handling_fee numeric(10,2) DEFAULT 0,
    handling_fee_percent numeric(5,4) DEFAULT 0,
    free_shipping_minimum numeric(10,2),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: shipping_carrier_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.shipping_carrier_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    carrier_type character varying(50) NOT NULL,
    display_name character varying(255) NOT NULL,
    description text,
    logo_url character varying(500),
    supports_rates boolean DEFAULT true,
    supports_tracking boolean DEFAULT true,
    supports_labels boolean DEFAULT true,
    supports_returns boolean DEFAULT false,
    supports_pickup boolean DEFAULT false,
    supported_countries text[] NOT NULL,
    supported_services text[],
    default_config jsonb,
    required_credentials text[] DEFAULT '{api_key}'::text[],
    setup_instructions text,
    documentation_url character varying(500),
    priority bigint DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: shipping_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.shipping_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    default_warehouse_id uuid,
    warehouse_name character varying(255),
    warehouse_company character varying(255),
    warehouse_phone character varying(50),
    warehouse_email character varying(255),
    warehouse_street character varying(500),
    warehouse_street2 character varying(500),
    warehouse_city character varying(255),
    warehouse_state character varying(100),
    warehouse_postal_code character varying(20),
    warehouse_country character varying(100),
    auto_select_carrier boolean DEFAULT true,
    preferred_carrier_type character varying(50),
    fallback_carrier_type character varying(50),
    selection_strategy character varying(50) DEFAULT 'priority'::character varying,
    free_shipping_enabled boolean DEFAULT false,
    free_shipping_minimum numeric(10,2),
    handling_fee numeric(10,2) DEFAULT 0,
    handling_fee_percent numeric(5,4) DEFAULT 1.5,
    default_weight_unit character varying(10) DEFAULT 'kg'::character varying,
    default_dimension_unit character varying(10) DEFAULT 'cm'::character varying,
    default_package_weight numeric(10,2) DEFAULT 0.5,
    insurance_enabled boolean DEFAULT false,
    insurance_min_value numeric(10,2),
    insurance_percentage numeric(5,4) DEFAULT 0.01,
    auto_insure_above_value numeric(10,2),
    send_shipment_notifications boolean DEFAULT true,
    send_delivery_notifications boolean DEFAULT true,
    send_tracking_updates boolean DEFAULT true,
    returns_enabled boolean DEFAULT true,
    return_window_days bigint DEFAULT 30,
    free_returns_enabled boolean DEFAULT false,
    return_label_mode character varying(50) DEFAULT 'on_request'::character varying,
    cache_rates boolean DEFAULT true,
    rate_cache_duration bigint DEFAULT 3600,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: task_execution_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.task_execution_logs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_task_id uuid NOT NULL,
    action text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb,
    error_message text,
    performed_by text NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: tenant_activity_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_activity_log (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    action character varying(100) NOT NULL,
    resource_type character varying(50),
    resource_id uuid,
    details jsonb DEFAULT '{}'::jsonb,
    ip_address character varying(45),
    user_agent text,
    created_at timestamp with time zone
);


--
-- Name: tenant_auth_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_auth_audit_log (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid,
    event_type character varying(50) NOT NULL,
    event_status character varying(20) DEFAULT 'success'::character varying NOT NULL,
    ip_address character varying(45),
    user_agent text,
    device_fingerprint character varying(255),
    geo_location jsonb,
    details jsonb DEFAULT '{}'::jsonb,
    error_message text,
    session_id character varying(255),
    created_at timestamp with time zone
);


--
-- Name: tenant_auth_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_auth_policies (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id uuid NOT NULL,
    password_min_length bigint DEFAULT 8,
    password_max_length bigint DEFAULT 128,
    password_require_uppercase boolean DEFAULT true,
    password_require_lowercase boolean DEFAULT true,
    password_require_numbers boolean DEFAULT true,
    password_require_special_chars boolean DEFAULT false,
    password_special_chars character varying(100),
    password_expiry_days bigint,
    password_history_count bigint DEFAULT 5,
    max_login_attempts bigint DEFAULT 5,
    lockout_duration_minutes bigint DEFAULT 30,
    session_timeout_minutes bigint DEFAULT 480,
    max_concurrent_sessions bigint DEFAULT 5,
    mfa_required boolean DEFAULT false,
    mfa_required_for_roles jsonb DEFAULT '["owner", "admin"]'::jsonb,
    mfa_allowed_types jsonb DEFAULT '["totp", "email"]'::jsonb,
    ip_whitelist_enabled boolean DEFAULT false,
    ip_whitelist jsonb DEFAULT '[]'::jsonb,
    trusted_devices_enabled boolean DEFAULT false,
    require_device_verification boolean DEFAULT false,
    sso_enabled boolean DEFAULT false,
    sso_provider character varying(50),
    sso_config jsonb DEFAULT '{}'::jsonb,
    sso_required boolean DEFAULT false,
    require_email_verification boolean DEFAULT true,
    allow_password_reset boolean DEFAULT true,
    password_reset_token_expiry_hours bigint DEFAULT 24,
    notify_on_new_device_login boolean DEFAULT true,
    notify_on_password_change boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    updated_by uuid,
    enable_progressive_lockout boolean DEFAULT true,
    tier1_lockout_minutes bigint DEFAULT 30,
    permanent_lockout_threshold bigint DEFAULT 7,
    lockout_reset_hours bigint DEFAULT 24
);


--
-- Name: tenant_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_credentials (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    password_hash text NOT NULL,
    password_set_at timestamp with time zone DEFAULT now(),
    password_expires_at timestamp with time zone,
    password_rotation_required boolean DEFAULT false,
    last_password_change_at timestamp with time zone,
    mfa_enabled boolean DEFAULT false,
    mfa_type character varying(20),
    mfa_secret character varying(255),
    mfa_backup_codes jsonb DEFAULT '[]'::jsonb,
    mfa_last_used_at timestamp with time zone,
    login_attempts bigint DEFAULT 0,
    last_login_attempt_at timestamp with time zone,
    locked_until timestamp with time zone,
    last_successful_login_at timestamp with time zone,
    last_login_ip character varying(45),
    last_login_user_agent text,
    active_sessions bigint DEFAULT 0,
    max_sessions bigint DEFAULT 5,
    password_history jsonb DEFAULT '[]'::jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_by uuid,
    updated_by uuid,
    lockout_count bigint DEFAULT 0,
    current_tier bigint DEFAULT 0,
    permanently_locked boolean DEFAULT false,
    permanent_locked_at timestamp with time zone,
    unlocked_by uuid,
    unlocked_at timestamp with time zone,
    total_failed_attempts bigint DEFAULT 0
);


--
-- Name: tenant_host_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_host_records (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    slug character varying(63) NOT NULL,
    admin_host character varying(255) NOT NULL,
    storefront_host character varying(255) NOT NULL,
    api_host character varying(255),
    cert_name character varying(255) NOT NULL,
    status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    certificate_created boolean DEFAULT false,
    gateway_patched boolean DEFAULT false,
    admin_vs_patched boolean DEFAULT false,
    storefront_vs_patched boolean DEFAULT false,
    api_vs_patched boolean DEFAULT false,
    certificate_namespace character varying(255),
    gateway_namespace character varying(255),
    admin_vs_namespace character varying(255),
    storefront_vs_namespace character varying(255),
    api_vs_namespace character varying(255),
    last_error text,
    retry_count bigint DEFAULT 0,
    last_retry_at timestamp with time zone,
    product character varying(100),
    business_name character varying(255),
    email character varying(255),
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    provisioned_at timestamp with time zone,
    storefront_www_host character varying(255),
    base_domain character varying(255),
    is_custom_domain boolean DEFAULT false,
    storefront_www_vs_patched boolean DEFAULT false,
    storefront_www_vs_namespace character varying(255)
);


--
-- Name: tenant_slug_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_slug_reservations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    slug character varying(50) NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    session_id uuid,
    tenant_id uuid,
    reserved_by character varying(255),
    expires_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    released_at timestamp with time zone
);


--
-- Name: tenant_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_users (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    keycloak_id uuid,
    email text NOT NULL,
    first_name text NOT NULL,
    last_name text NOT NULL,
    phone text,
    status text DEFAULT 'active'::text,
    password text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenants (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name text NOT NULL,
    slug character varying(50) NOT NULL,
    subdomain text NOT NULL,
    display_name character varying(255),
    logo_url text,
    business_type text,
    industry text,
    status text DEFAULT 'creating'::text,
    mode text DEFAULT 'development'::text,
    business_model character varying(50) DEFAULT 'ONLINE_STORE'::character varying,
    primary_color character varying(7) DEFAULT '#6366f1'::character varying,
    secondary_color character varying(7) DEFAULT '#8b5cf6'::character varying,
    default_timezone character varying(50) DEFAULT 'UTC'::character varying,
    default_currency character varying(3) DEFAULT 'USD'::character varying,
    pricing_tier character varying(50) DEFAULT 'free'::character varying,
    pricing_tier_updated_at timestamp with time zone,
    trial_ends_at timestamp with time zone,
    billing_email character varying(255),
    owner_user_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    keycloak_org_id uuid,
    growth_book_org_id character varying(255),
    growth_book_sdk_key character varying(255),
    growth_book_admin_key character varying(255),
    growth_book_enabled boolean DEFAULT false,
    growth_book_provisioned_at timestamp with time zone,
    admin_url character varying(255),
    storefront_url character varying(255),
    api_url character varying(255),
    use_custom_domain boolean DEFAULT false,
    custom_domain character varying(255),
    favicon_url text
);


--
-- Name: user_tenant_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.user_tenant_memberships (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    role character varying(50) DEFAULT 'member'::character varying NOT NULL,
    permissions jsonb DEFAULT '{}'::jsonb,
    is_default boolean DEFAULT false,
    is_active boolean DEFAULT true,
    invited_by uuid,
    invited_at timestamp with time zone,
    invitation_token character varying(255),
    invitation_expires_at timestamp with time zone,
    accepted_at timestamp with time zone,
    last_accessed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: verification_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.verification_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    verification_code_id uuid NOT NULL,
    ip_address character varying(45),
    user_agent text,
    success boolean DEFAULT false,
    failure_reason character varying(255),
    created_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: verification_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.verification_codes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recipient character varying(255) NOT NULL,
    channel character varying(20) NOT NULL,
    code text NOT NULL,
    code_hash character varying(64) NOT NULL,
    purpose character varying(50) NOT NULL,
    session_id uuid,
    tenant_id uuid,
    expires_at timestamp with time zone NOT NULL,
    verified_at timestamp with time zone,
    attempt_count bigint DEFAULT 0,
    max_attempts bigint DEFAULT 3,
    is_used boolean DEFAULT false,
    metadata jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: verification_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.verification_records (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    verification_type text NOT NULL,
    verification_method text NOT NULL,
    target_value text NOT NULL,
    verification_code text,
    status text DEFAULT 'pending'::text,
    attempts bigint DEFAULT 0,
    max_attempts bigint DEFAULT 5,
    expires_at timestamp with time zone,
    verified_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: webhook_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.webhook_events (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    event_type text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    webhook_url text,
    status text DEFAULT 'pending'::text,
    attempts bigint DEFAULT 0,
    max_attempts bigint DEFAULT 3,
    next_retry_at timestamp with time zone,
    response_status bigint,
    response_body text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: address_cache id; Type: DEFAULT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.address_cache ALTER COLUMN id SET DEFAULT nextval('location.address_cache_id_seq'::regclass);


--
-- Name: location_cache id; Type: DEFAULT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.location_cache ALTER COLUMN id SET DEFAULT nextval('location.location_cache_id_seq'::regclass);


--
-- Name: address_cache address_cache_pkey; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.address_cache
    ADD CONSTRAINT address_cache_pkey PRIMARY KEY (id);


--
-- Name: address_cache address_cache_unique_key; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.address_cache
    ADD CONSTRAINT address_cache_unique_key UNIQUE (cache_type, cache_key_hash);


--
-- Name: countries countries_pkey; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.countries
    ADD CONSTRAINT countries_pkey PRIMARY KEY (id);


--
-- Name: currencies currencies_pkey; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.currencies
    ADD CONSTRAINT currencies_pkey PRIMARY KEY (code);


--
-- Name: location_cache location_cache_ip_key; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.location_cache
    ADD CONSTRAINT location_cache_ip_key UNIQUE (ip);


--
-- Name: location_cache location_cache_pkey; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.location_cache
    ADD CONSTRAINT location_cache_pkey PRIMARY KEY (id);


--
-- Name: places places_pkey; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.places
    ADD CONSTRAINT places_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: states states_pkey; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.states
    ADD CONSTRAINT states_pkey PRIMARY KEY (id);


--
-- Name: timezones timezones_pkey; Type: CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.timezones
    ADD CONSTRAINT timezones_pkey PRIMARY KEY (id);


--
-- Name: ad_billing_invoices ad_billing_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_billing_invoices
    ADD CONSTRAINT ad_billing_invoices_pkey PRIMARY KEY (id);


--
-- Name: ad_campaign_payments ad_campaign_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_campaign_payments
    ADD CONSTRAINT ad_campaign_payments_pkey PRIMARY KEY (id);


--
-- Name: ad_commission_tiers ad_commission_tiers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_commission_tiers
    ADD CONSTRAINT ad_commission_tiers_pkey PRIMARY KEY (id);


--
-- Name: ad_revenue_ledger ad_revenue_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_revenue_ledger
    ADD CONSTRAINT ad_revenue_ledger_pkey PRIMARY KEY (id);


--
-- Name: ad_vendor_balances ad_vendor_balances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_vendor_balances
    ADD CONSTRAINT ad_vendor_balances_pkey PRIMARY KEY (id);


--
-- Name: application_configurations application_configurations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_configurations
    ADD CONSTRAINT application_configurations_pkey PRIMARY KEY (id);


--
-- Name: business_addresses business_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_addresses
    ADD CONSTRAINT business_addresses_pkey PRIMARY KEY (id);


--
-- Name: business_informations business_informations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_informations
    ADD CONSTRAINT business_informations_pkey PRIMARY KEY (id);


--
-- Name: contact_informations contact_informations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_informations
    ADD CONSTRAINT contact_informations_pkey PRIMARY KEY (id);


--
-- Name: deactivated_memberships deactivated_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deactivated_memberships
    ADD CONSTRAINT deactivated_memberships_pkey PRIMARY KEY (id);


--
-- Name: deleted_tenants deleted_tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deleted_tenants
    ADD CONSTRAINT deleted_tenants_pkey PRIMARY KEY (id);


--
-- Name: domain_reservations domain_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.domain_reservations
    ADD CONSTRAINT domain_reservations_pkey PRIMARY KEY (id);


--
-- Name: gateway_customers gateway_customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gateway_customers
    ADD CONSTRAINT gateway_customers_pkey PRIMARY KEY (id);


--
-- Name: marketplace_connections marketplace_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_connections
    ADD CONSTRAINT marketplace_connections_pkey PRIMARY KEY (id);


--
-- Name: marketplace_credentials marketplace_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_credentials
    ADD CONSTRAINT marketplace_credentials_pkey PRIMARY KEY (id);


--
-- Name: marketplace_inventory_mappings marketplace_inventory_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_inventory_mappings
    ADD CONSTRAINT marketplace_inventory_mappings_pkey PRIMARY KEY (id);


--
-- Name: marketplace_order_mappings marketplace_order_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_order_mappings
    ADD CONSTRAINT marketplace_order_mappings_pkey PRIMARY KEY (id);


--
-- Name: marketplace_product_mappings marketplace_product_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_product_mappings
    ADD CONSTRAINT marketplace_product_mappings_pkey PRIMARY KEY (id);


--
-- Name: marketplace_sync_jobs marketplace_sync_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_sync_jobs
    ADD CONSTRAINT marketplace_sync_jobs_pkey PRIMARY KEY (id);


--
-- Name: marketplace_sync_logs marketplace_sync_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_sync_logs
    ADD CONSTRAINT marketplace_sync_logs_pkey PRIMARY KEY (id);


--
-- Name: marketplace_webhook_events marketplace_webhook_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_webhook_events
    ADD CONSTRAINT marketplace_webhook_events_pkey PRIMARY KEY (id);


--
-- Name: onboarding_notifications onboarding_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_notifications
    ADD CONSTRAINT onboarding_notifications_pkey PRIMARY KEY (id);


--
-- Name: onboarding_sessions onboarding_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_sessions
    ADD CONSTRAINT onboarding_sessions_pkey PRIMARY KEY (id);


--
-- Name: onboarding_tasks onboarding_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_tasks
    ADD CONSTRAINT onboarding_tasks_pkey PRIMARY KEY (id);


--
-- Name: onboarding_templates onboarding_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_templates
    ADD CONSTRAINT onboarding_templates_pkey PRIMARY KEY (id);


--
-- Name: password_reset_tokens password_reset_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_pkey PRIMARY KEY (id);


--
-- Name: payment_disputes payment_disputes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_disputes
    ADD CONSTRAINT payment_disputes_pkey PRIMARY KEY (id);


--
-- Name: payment_gateway_configs payment_gateway_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_gateway_configs
    ADD CONSTRAINT payment_gateway_configs_pkey PRIMARY KEY (id);


--
-- Name: payment_gateway_regions payment_gateway_regions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_gateway_regions
    ADD CONSTRAINT payment_gateway_regions_pkey PRIMARY KEY (id);


--
-- Name: payment_gateway_templates payment_gateway_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_gateway_templates
    ADD CONSTRAINT payment_gateway_templates_pkey PRIMARY KEY (id);


--
-- Name: payment_informations payment_informations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_informations
    ADD CONSTRAINT payment_informations_pkey PRIMARY KEY (id);


--
-- Name: payment_settings payment_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_settings
    ADD CONSTRAINT payment_settings_pkey PRIMARY KEY (id);


--
-- Name: payment_transactions payment_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_transactions
    ADD CONSTRAINT payment_transactions_pkey PRIMARY KEY (id);


--
-- Name: payment_webhook_events payment_webhook_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_webhook_events
    ADD CONSTRAINT payment_webhook_events_pkey PRIMARY KEY (id);


--
-- Name: platform_fee_ledger platform_fee_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_fee_ledger
    ADD CONSTRAINT platform_fee_ledger_pkey PRIMARY KEY (id);


--
-- Name: provisioning_activity_logs provisioning_activity_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provisioning_activity_logs
    ADD CONSTRAINT provisioning_activity_logs_pkey PRIMARY KEY (id);


--
-- Name: rate_limits rate_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rate_limits
    ADD CONSTRAINT rate_limits_pkey PRIMARY KEY (id);


--
-- Name: refund_transactions refund_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refund_transactions
    ADD CONSTRAINT refund_transactions_pkey PRIMARY KEY (id);


--
-- Name: reserved_slugs reserved_slugs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reserved_slugs
    ADD CONSTRAINT reserved_slugs_pkey PRIMARY KEY (id);


--
-- Name: saved_payment_methods saved_payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_payment_methods
    ADD CONSTRAINT saved_payment_methods_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: secret_audit_log secret_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_audit_log
    ADD CONSTRAINT secret_audit_log_pkey PRIMARY KEY (id);


--
-- Name: secret_metadata secret_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secret_metadata
    ADD CONSTRAINT secret_metadata_pkey PRIMARY KEY (id);


--
-- Name: shipment_trackings shipment_trackings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipment_trackings
    ADD CONSTRAINT shipment_trackings_pkey PRIMARY KEY (id);


--
-- Name: shipments shipments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT shipments_pkey PRIMARY KEY (id);


--
-- Name: shipping_carrier_configs shipping_carrier_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipping_carrier_configs
    ADD CONSTRAINT shipping_carrier_configs_pkey PRIMARY KEY (id);


--
-- Name: shipping_carrier_regions shipping_carrier_regions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipping_carrier_regions
    ADD CONSTRAINT shipping_carrier_regions_pkey PRIMARY KEY (id);


--
-- Name: shipping_carrier_templates shipping_carrier_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipping_carrier_templates
    ADD CONSTRAINT shipping_carrier_templates_pkey PRIMARY KEY (id);


--
-- Name: shipping_settings shipping_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipping_settings
    ADD CONSTRAINT shipping_settings_pkey PRIMARY KEY (id);


--
-- Name: task_execution_logs task_execution_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_execution_logs
    ADD CONSTRAINT task_execution_logs_pkey PRIMARY KEY (id);


--
-- Name: tenant_activity_log tenant_activity_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_activity_log
    ADD CONSTRAINT tenant_activity_log_pkey PRIMARY KEY (id);


--
-- Name: tenant_auth_audit_log tenant_auth_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_auth_audit_log
    ADD CONSTRAINT tenant_auth_audit_log_pkey PRIMARY KEY (id);


--
-- Name: tenant_auth_policies tenant_auth_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_auth_policies
    ADD CONSTRAINT tenant_auth_policies_pkey PRIMARY KEY (id);


--
-- Name: tenant_credentials tenant_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_credentials
    ADD CONSTRAINT tenant_credentials_pkey PRIMARY KEY (id);


--
-- Name: tenant_host_records tenant_host_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_host_records
    ADD CONSTRAINT tenant_host_records_pkey PRIMARY KEY (id);


--
-- Name: tenant_slug_reservations tenant_slug_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_slug_reservations
    ADD CONSTRAINT tenant_slug_reservations_pkey PRIMARY KEY (id);


--
-- Name: tenant_users tenant_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_users
    ADD CONSTRAINT tenant_users_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: domain_reservations uni_domain_reservations_domain_value; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.domain_reservations
    ADD CONSTRAINT uni_domain_reservations_domain_value UNIQUE (domain_value);


--
-- Name: payment_gateway_templates uni_payment_gateway_templates_gateway_type; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_gateway_templates
    ADD CONSTRAINT uni_payment_gateway_templates_gateway_type UNIQUE (gateway_type);


--
-- Name: payment_settings uni_payment_settings_tenant_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_settings
    ADD CONSTRAINT uni_payment_settings_tenant_id UNIQUE (tenant_id);


--
-- Name: reserved_slugs uni_reserved_slugs_slug; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reserved_slugs
    ADD CONSTRAINT uni_reserved_slugs_slug UNIQUE (slug);


--
-- Name: saved_payment_methods uni_saved_payment_methods_gateway_payment_method_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_payment_methods
    ADD CONSTRAINT uni_saved_payment_methods_gateway_payment_method_id UNIQUE (gateway_payment_method_id);


--
-- Name: shipping_carrier_templates uni_shipping_carrier_templates_carrier_type; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipping_carrier_templates
    ADD CONSTRAINT uni_shipping_carrier_templates_carrier_type UNIQUE (carrier_type);


--
-- Name: shipping_settings uni_shipping_settings_tenant_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipping_settings
    ADD CONSTRAINT uni_shipping_settings_tenant_id UNIQUE (tenant_id);


--
-- Name: tenant_auth_policies uni_tenant_auth_policies_tenant_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_auth_policies
    ADD CONSTRAINT uni_tenant_auth_policies_tenant_id UNIQUE (tenant_id);


--
-- Name: tenant_slug_reservations uni_tenant_slug_reservations_slug; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_slug_reservations
    ADD CONSTRAINT uni_tenant_slug_reservations_slug UNIQUE (slug);


--
-- Name: tenant_users uni_tenant_users_email; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_users
    ADD CONSTRAINT uni_tenant_users_email UNIQUE (email);


--
-- Name: tenants uni_tenants_slug; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT uni_tenants_slug UNIQUE (slug);


--
-- Name: tenants uni_tenants_subdomain; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT uni_tenants_subdomain UNIQUE (subdomain);


--
-- Name: user_tenant_memberships user_tenant_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tenant_memberships
    ADD CONSTRAINT user_tenant_memberships_pkey PRIMARY KEY (id);


--
-- Name: verification_attempts verification_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_attempts
    ADD CONSTRAINT verification_attempts_pkey PRIMARY KEY (id);


--
-- Name: verification_codes verification_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_codes
    ADD CONSTRAINT verification_codes_pkey PRIMARY KEY (id);


--
-- Name: verification_records verification_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_records
    ADD CONSTRAINT verification_records_pkey PRIMARY KEY (id);


--
-- Name: webhook_events webhook_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_events
    ADD CONSTRAINT webhook_events_pkey PRIMARY KEY (id);


--
-- Name: idx_address_cache_coords; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_address_cache_coords ON location.address_cache USING btree (latitude, longitude) WHERE ((latitude IS NOT NULL) AND (longitude IS NOT NULL));


--
-- Name: idx_address_cache_country; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_address_cache_country ON location.address_cache USING btree (country_code) WHERE (country_code IS NOT NULL);


--
-- Name: idx_address_cache_expires; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_address_cache_expires ON location.address_cache USING btree (expires_at);


--
-- Name: idx_address_cache_lookup; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_address_cache_lookup ON location.address_cache USING btree (cache_type, cache_key_hash);


--
-- Name: idx_countries_active; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_countries_active ON location.countries USING btree (active);


--
-- Name: idx_countries_deleted_at; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_countries_deleted_at ON location.countries USING btree (deleted_at);


--
-- Name: idx_countries_name; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_countries_name ON location.countries USING btree (name);


--
-- Name: idx_countries_region; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_countries_region ON location.countries USING btree (region);


--
-- Name: idx_currencies_active; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_currencies_active ON location.currencies USING btree (active);


--
-- Name: idx_currencies_deleted_at; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_currencies_deleted_at ON location.currencies USING btree (deleted_at);


--
-- Name: idx_location_cache_expires_at; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_location_cache_expires_at ON location.location_cache USING btree (expires_at);


--
-- Name: idx_location_cache_ip; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_location_cache_ip ON location.location_cache USING btree (ip);


--
-- Name: idx_places_city; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_places_city ON location.places USING btree (city, country_code) WHERE (city IS NOT NULL);


--
-- Name: idx_places_country; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_places_country ON location.places USING btree (country_code) WHERE (country_code IS NOT NULL);


--
-- Name: idx_places_deleted; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_places_deleted ON location.places USING btree (deleted_at) WHERE (deleted_at IS NULL);


--
-- Name: idx_places_external_id; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_places_external_id ON location.places USING btree (external_place_id) WHERE (external_place_id IS NOT NULL);


--
-- Name: idx_places_geohash; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_places_geohash ON location.places USING btree (geohash) WHERE (geohash IS NOT NULL);


--
-- Name: idx_places_postal; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_places_postal ON location.places USING btree (postal_code, country_code) WHERE (postal_code IS NOT NULL);


--
-- Name: idx_places_search; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_places_search ON location.places USING gin (search_vector);


--
-- Name: idx_states_active; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_states_active ON location.states USING btree (active);


--
-- Name: idx_states_code; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_states_code ON location.states USING btree (code);


--
-- Name: idx_states_country_id; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_states_country_id ON location.states USING btree (country_id);


--
-- Name: idx_states_deleted_at; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_states_deleted_at ON location.states USING btree (deleted_at);


--
-- Name: idx_states_name; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_states_name ON location.states USING btree (name);


--
-- Name: idx_timezones_deleted_at; Type: INDEX; Schema: location; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_timezones_deleted_at ON location.timezones USING btree (deleted_at);


--
-- Name: idx_activity_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_activity_created ON public.provisioning_activity_logs USING btree (tenant_host_id, created_at DESC);


--
-- Name: idx_activity_tenant_host; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_activity_tenant_host ON public.provisioning_activity_logs USING btree (tenant_host_id);


--
-- Name: idx_ad_billing_invoices_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_billing_invoices_due ON public.ad_billing_invoices USING btree (due_date);


--
-- Name: idx_ad_billing_invoices_invoice_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_ad_billing_invoices_invoice_number ON public.ad_billing_invoices USING btree (invoice_number);


--
-- Name: idx_ad_billing_invoices_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_billing_invoices_status ON public.ad_billing_invoices USING btree (status);


--
-- Name: idx_ad_billing_invoices_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_billing_invoices_tenant ON public.ad_billing_invoices USING btree (tenant_id);


--
-- Name: idx_ad_billing_invoices_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_billing_invoices_vendor ON public.ad_billing_invoices USING btree (vendor_id);


--
-- Name: idx_ad_campaign_payments_campaign; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_campaign_payments_campaign ON public.ad_campaign_payments USING btree (campaign_id);


--
-- Name: idx_ad_campaign_payments_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_campaign_payments_created ON public.ad_campaign_payments USING btree (created_at);


--
-- Name: idx_ad_campaign_payments_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_campaign_payments_status ON public.ad_campaign_payments USING btree (status);


--
-- Name: idx_ad_campaign_payments_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_campaign_payments_tenant ON public.ad_campaign_payments USING btree (tenant_id);


--
-- Name: idx_ad_campaign_payments_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_campaign_payments_vendor ON public.ad_campaign_payments USING btree (vendor_id);


--
-- Name: idx_ad_commission_tiers_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_commission_tiers_active ON public.ad_commission_tiers USING btree (is_active);


--
-- Name: idx_ad_commission_tiers_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_commission_tiers_tenant ON public.ad_commission_tiers USING btree (tenant_id);


--
-- Name: idx_ad_revenue_ledger_campaign; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_revenue_ledger_campaign ON public.ad_revenue_ledger USING btree (campaign_id);


--
-- Name: idx_ad_revenue_ledger_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_revenue_ledger_created ON public.ad_revenue_ledger USING btree (created_at);


--
-- Name: idx_ad_revenue_ledger_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_revenue_ledger_tenant ON public.ad_revenue_ledger USING btree (tenant_id);


--
-- Name: idx_ad_revenue_ledger_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_revenue_ledger_type ON public.ad_revenue_ledger USING btree (entry_type);


--
-- Name: idx_ad_revenue_ledger_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_revenue_ledger_vendor ON public.ad_revenue_ledger USING btree (vendor_id);


--
-- Name: idx_ad_vendor_balances_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_vendor_balances_tenant ON public.ad_vendor_balances USING btree (tenant_id);


--
-- Name: idx_ad_vendor_balances_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_ad_vendor_balances_vendor ON public.ad_vendor_balances USING btree (vendor_id);


--
-- Name: idx_application_configurations_onboarding_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_application_configurations_onboarding_session_id ON public.application_configurations USING btree (onboarding_session_id);


--
-- Name: idx_audit_secret; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_secret ON public.secret_audit_log USING btree (secret_name);


--
-- Name: idx_audit_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_tenant ON public.secret_audit_log USING btree (tenant_id);


--
-- Name: idx_audit_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_time ON public.secret_audit_log USING btree (created_at);


--
-- Name: idx_business_addresses_onboarding_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_business_addresses_onboarding_session_id ON public.business_addresses USING btree (onboarding_session_id);


--
-- Name: idx_business_informations_onboarding_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_business_informations_onboarding_session_id ON public.business_informations USING btree (onboarding_session_id);


--
-- Name: idx_business_informations_tenant_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_business_informations_tenant_slug ON public.business_informations USING btree (tenant_slug);


--
-- Name: idx_carrier_regions_carrier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_carrier_regions_carrier ON public.shipping_carrier_regions USING btree (carrier_config_id);


--
-- Name: idx_carrier_regions_country; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_carrier_regions_country ON public.shipping_carrier_regions USING btree (country_code);


--
-- Name: idx_carrier_regions_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_carrier_regions_enabled ON public.shipping_carrier_regions USING btree (enabled);


--
-- Name: idx_contact_informations_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_contact_informations_email ON public.contact_informations USING btree (email);


--
-- Name: idx_contact_informations_onboarding_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_contact_informations_onboarding_session_id ON public.contact_informations USING btree (onboarding_session_id);


--
-- Name: idx_deactivated_memberships_deactivated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deactivated_memberships_deactivated_at ON public.deactivated_memberships USING btree (deactivated_at);


--
-- Name: idx_deactivated_memberships_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deactivated_memberships_email ON public.deactivated_memberships USING btree (email);


--
-- Name: idx_deactivated_memberships_is_purged; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deactivated_memberships_is_purged ON public.deactivated_memberships USING btree (is_purged);


--
-- Name: idx_deactivated_memberships_original_membership_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deactivated_memberships_original_membership_id ON public.deactivated_memberships USING btree (original_membership_id);


--
-- Name: idx_deactivated_memberships_scheduled_purge_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deactivated_memberships_scheduled_purge_at ON public.deactivated_memberships USING btree (scheduled_purge_at);


--
-- Name: idx_deactivated_memberships_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deactivated_memberships_tenant_id ON public.deactivated_memberships USING btree (tenant_id);


--
-- Name: idx_deactivated_memberships_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deactivated_memberships_user_id ON public.deactivated_memberships USING btree (user_id);


--
-- Name: idx_deleted_tenants_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deleted_tenants_deleted_at ON public.deleted_tenants USING btree (deleted_at);


--
-- Name: idx_deleted_tenants_deleted_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deleted_tenants_deleted_by_user_id ON public.deleted_tenants USING btree (deleted_by_user_id);


--
-- Name: idx_deleted_tenants_original_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deleted_tenants_original_tenant_id ON public.deleted_tenants USING btree (original_tenant_id);


--
-- Name: idx_deleted_tenants_owner_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deleted_tenants_owner_email ON public.deleted_tenants USING btree (owner_email);


--
-- Name: idx_deleted_tenants_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_deleted_tenants_slug ON public.deleted_tenants USING btree (slug);


--
-- Name: idx_disputes_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_disputes_payment ON public.payment_disputes USING btree (payment_transaction_id);


--
-- Name: idx_disputes_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_disputes_status ON public.payment_disputes USING btree (status);


--
-- Name: idx_disputes_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_disputes_tenant ON public.payment_disputes USING btree (tenant_id);


--
-- Name: idx_domain_reservations_domain_value; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_domain_reservations_domain_value ON public.domain_reservations USING btree (domain_value);


--
-- Name: idx_domain_reservations_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_domain_reservations_status ON public.domain_reservations USING btree (status);


--
-- Name: idx_gateway_customers_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gateway_customers_customer ON public.gateway_customers USING btree (customer_id);


--
-- Name: idx_gateway_customers_gateway; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gateway_customers_gateway ON public.gateway_customers USING btree (gateway_type);


--
-- Name: idx_gateway_customers_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gateway_customers_tenant ON public.gateway_customers USING btree (tenant_id);


--
-- Name: idx_gateway_regions_country; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gateway_regions_country ON public.payment_gateway_regions USING btree (country_code);


--
-- Name: idx_gateway_regions_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gateway_regions_enabled ON public.payment_gateway_regions USING btree (enabled);


--
-- Name: idx_gateway_regions_gateway; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gateway_regions_gateway ON public.payment_gateway_regions USING btree (gateway_config_id);


--
-- Name: idx_marketplace_credentials_connection_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_marketplace_credentials_connection_id ON public.marketplace_credentials USING btree (connection_id);


--
-- Name: idx_mp_connections_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_connections_status ON public.marketplace_connections USING btree (status);


--
-- Name: idx_mp_connections_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_connections_tenant ON public.marketplace_connections USING btree (tenant_id);


--
-- Name: idx_mp_connections_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_connections_type ON public.marketplace_connections USING btree (marketplace_type);


--
-- Name: idx_mp_connections_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_connections_vendor ON public.marketplace_connections USING btree (vendor_id);


--
-- Name: idx_mp_inventory_mapping_connection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_inventory_mapping_connection ON public.marketplace_inventory_mappings USING btree (connection_id);


--
-- Name: idx_mp_inventory_mapping_external; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_inventory_mapping_external ON public.marketplace_inventory_mappings USING btree (external_sku);


--
-- Name: idx_mp_inventory_mapping_internal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_inventory_mapping_internal ON public.marketplace_inventory_mappings USING btree (internal_product_id);


--
-- Name: idx_mp_inventory_mapping_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_inventory_mapping_tenant ON public.marketplace_inventory_mappings USING btree (tenant_id);


--
-- Name: idx_mp_order_mapping_connection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_order_mapping_connection ON public.marketplace_order_mappings USING btree (connection_id);


--
-- Name: idx_mp_order_mapping_external; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_order_mapping_external ON public.marketplace_order_mappings USING btree (external_order_id);


--
-- Name: idx_mp_order_mapping_internal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_order_mapping_internal ON public.marketplace_order_mappings USING btree (internal_order_id);


--
-- Name: idx_mp_order_mapping_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_order_mapping_tenant ON public.marketplace_order_mappings USING btree (tenant_id);


--
-- Name: idx_mp_product_mapping_connection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_product_mapping_connection ON public.marketplace_product_mappings USING btree (connection_id);


--
-- Name: idx_mp_product_mapping_external; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_product_mapping_external ON public.marketplace_product_mappings USING btree (external_product_id);


--
-- Name: idx_mp_product_mapping_internal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_product_mapping_internal ON public.marketplace_product_mappings USING btree (internal_product_id);


--
-- Name: idx_mp_product_mapping_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_product_mapping_tenant ON public.marketplace_product_mappings USING btree (tenant_id);


--
-- Name: idx_mp_sync_jobs_connection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_sync_jobs_connection ON public.marketplace_sync_jobs USING btree (connection_id);


--
-- Name: idx_mp_sync_jobs_scheduled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_sync_jobs_scheduled ON public.marketplace_sync_jobs USING btree (scheduled_at);


--
-- Name: idx_mp_sync_jobs_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_sync_jobs_status ON public.marketplace_sync_jobs USING btree (status);


--
-- Name: idx_mp_sync_jobs_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_sync_jobs_tenant ON public.marketplace_sync_jobs USING btree (tenant_id);


--
-- Name: idx_mp_sync_logs_job; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_sync_logs_job ON public.marketplace_sync_logs USING btree (sync_job_id);


--
-- Name: idx_mp_sync_logs_level; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_sync_logs_level ON public.marketplace_sync_logs USING btree (level);


--
-- Name: idx_mp_webhook_connection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_webhook_connection ON public.marketplace_webhook_events USING btree (connection_id);


--
-- Name: idx_mp_webhook_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_webhook_created ON public.marketplace_webhook_events USING btree (created_at);


--
-- Name: idx_mp_webhook_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_webhook_event_type ON public.marketplace_webhook_events USING btree (event_type);


--
-- Name: idx_mp_webhook_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_webhook_idempotency ON public.marketplace_webhook_events USING btree (idempotency_key);


--
-- Name: idx_mp_webhook_processed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_webhook_processed ON public.marketplace_webhook_events USING btree (processed);


--
-- Name: idx_mp_webhook_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_webhook_tenant ON public.marketplace_webhook_events USING btree (tenant_id);


--
-- Name: idx_mp_webhook_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_mp_webhook_type ON public.marketplace_webhook_events USING btree (marketplace_type);


--
-- Name: idx_onboarding_notifications_onboarding_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_notifications_onboarding_session_id ON public.onboarding_notifications USING btree (onboarding_session_id);


--
-- Name: idx_onboarding_notifications_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_notifications_status ON public.onboarding_notifications USING btree (status);


--
-- Name: idx_onboarding_sessions_application_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_sessions_application_type ON public.onboarding_sessions USING btree (application_type);


--
-- Name: idx_onboarding_sessions_business_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_sessions_business_model ON public.onboarding_sessions USING btree (business_model);


--
-- Name: idx_onboarding_sessions_current_step; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_sessions_current_step ON public.onboarding_sessions USING btree (current_step);


--
-- Name: idx_onboarding_sessions_draft_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_sessions_draft_expires_at ON public.onboarding_sessions USING btree (draft_expires_at);


--
-- Name: idx_onboarding_sessions_draft_saved_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_sessions_draft_saved_at ON public.onboarding_sessions USING btree (draft_saved_at);


--
-- Name: idx_onboarding_sessions_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_sessions_expires_at ON public.onboarding_sessions USING btree (expires_at);


--
-- Name: idx_onboarding_sessions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_sessions_status ON public.onboarding_sessions USING btree (status);


--
-- Name: idx_onboarding_sessions_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_sessions_tenant_id ON public.onboarding_sessions USING btree (tenant_id);


--
-- Name: idx_onboarding_tasks_onboarding_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_tasks_onboarding_session_id ON public.onboarding_tasks USING btree (onboarding_session_id);


--
-- Name: idx_onboarding_tasks_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_onboarding_tasks_status ON public.onboarding_tasks USING btree (status);


--
-- Name: idx_password_reset_tokens_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_email ON public.password_reset_tokens USING btree (email);


--
-- Name: idx_password_reset_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_expires_at ON public.password_reset_tokens USING btree (expires_at);


--
-- Name: idx_password_reset_tokens_is_used; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_is_used ON public.password_reset_tokens USING btree (is_used);


--
-- Name: idx_password_reset_tokens_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_tenant_id ON public.password_reset_tokens USING btree (tenant_id);


--
-- Name: idx_password_reset_tokens_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_password_reset_tokens_token ON public.password_reset_tokens USING btree (token);


--
-- Name: idx_password_reset_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_password_reset_tokens_user_id ON public.password_reset_tokens USING btree (user_id);


--
-- Name: idx_payment_gateways_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_gateways_enabled ON public.payment_gateway_configs USING btree (is_enabled);


--
-- Name: idx_payment_gateways_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_gateways_tenant ON public.payment_gateway_configs USING btree (tenant_id);


--
-- Name: idx_payment_informations_onboarding_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_informations_onboarding_session_id ON public.payment_informations USING btree (onboarding_session_id);


--
-- Name: idx_payment_informations_payment_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_informations_payment_status ON public.payment_informations USING btree (payment_status);


--
-- Name: idx_payment_settings_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_settings_tenant ON public.payment_settings USING btree (tenant_id);


--
-- Name: idx_payment_transactions_country; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_transactions_country ON public.payment_transactions USING btree (country_code);


--
-- Name: idx_payment_transactions_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_transactions_created ON public.payment_transactions USING btree (created_at);


--
-- Name: idx_payment_transactions_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_transactions_customer ON public.payment_transactions USING btree (customer_id);


--
-- Name: idx_payment_transactions_gateway_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_transactions_gateway_id ON public.payment_transactions USING btree (gateway_transaction_id);


--
-- Name: idx_payment_transactions_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_transactions_idempotency ON public.payment_transactions USING btree (idempotency_key);


--
-- Name: idx_payment_transactions_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_transactions_order ON public.payment_transactions USING btree (order_id);


--
-- Name: idx_payment_transactions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_transactions_status ON public.payment_transactions USING btree (status);


--
-- Name: idx_payment_transactions_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_payment_transactions_tenant ON public.payment_transactions USING btree (tenant_id);


--
-- Name: idx_platform_fee_ledger_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_platform_fee_ledger_created ON public.platform_fee_ledger USING btree (created_at);


--
-- Name: idx_platform_fee_ledger_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_platform_fee_ledger_payment ON public.platform_fee_ledger USING btree (payment_transaction_id);


--
-- Name: idx_platform_fee_ledger_refund; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_platform_fee_ledger_refund ON public.platform_fee_ledger USING btree (refund_transaction_id);


--
-- Name: idx_platform_fee_ledger_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_platform_fee_ledger_status ON public.platform_fee_ledger USING btree (status);


--
-- Name: idx_platform_fee_ledger_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_platform_fee_ledger_tenant ON public.platform_fee_ledger USING btree (tenant_id);


--
-- Name: idx_rate_limits_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_rate_limits_deleted_at ON public.rate_limits USING btree (deleted_at);


--
-- Name: idx_rate_limits_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_rate_limits_identifier ON public.rate_limits USING btree (identifier);


--
-- Name: idx_rate_limits_window_end; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_rate_limits_window_end ON public.rate_limits USING btree (window_end);


--
-- Name: idx_refunds_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_refunds_payment ON public.refund_transactions USING btree (payment_transaction_id);


--
-- Name: idx_refunds_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_refunds_status ON public.refund_transactions USING btree (status);


--
-- Name: idx_refunds_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_refunds_tenant ON public.refund_transactions USING btree (tenant_id);


--
-- Name: idx_saved_payment_methods_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_saved_payment_methods_customer ON public.saved_payment_methods USING btree (customer_id);


--
-- Name: idx_saved_payment_methods_gateway; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_saved_payment_methods_gateway ON public.saved_payment_methods USING btree (gateway_config_id);


--
-- Name: idx_saved_payment_methods_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_saved_payment_methods_tenant ON public.saved_payment_methods USING btree (tenant_id);


--
-- Name: idx_secret_meta_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_secret_meta_category ON public.secret_metadata USING btree (category);


--
-- Name: idx_secret_meta_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_secret_meta_provider ON public.secret_metadata USING btree (provider);


--
-- Name: idx_secret_meta_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_secret_meta_tenant ON public.secret_metadata USING btree (tenant_id);


--
-- Name: idx_secret_metadata_gcp_secret_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_secret_metadata_gcp_secret_name ON public.secret_metadata USING btree (gcp_secret_name);


--
-- Name: idx_shipment_trackings_shipment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipment_trackings_shipment_id ON public.shipment_trackings USING btree (shipment_id);


--
-- Name: idx_shipments_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipments_order_id ON public.shipments USING btree (order_id);


--
-- Name: idx_shipments_order_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipments_order_number ON public.shipments USING btree (order_number);


--
-- Name: idx_shipments_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipments_tenant_id ON public.shipments USING btree (tenant_id);


--
-- Name: idx_shipments_tracking_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipments_tracking_number ON public.shipments USING btree (tracking_number);


--
-- Name: idx_shipping_carriers_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipping_carriers_enabled ON public.shipping_carrier_configs USING btree (is_enabled);


--
-- Name: idx_shipping_carriers_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipping_carriers_tenant ON public.shipping_carrier_configs USING btree (tenant_id);


--
-- Name: idx_shipping_settings_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipping_settings_tenant ON public.shipping_settings USING btree (tenant_id);


--
-- Name: idx_sync_jobs_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_sync_jobs_idempotency ON public.marketplace_sync_jobs USING btree (idempotency_key);


--
-- Name: idx_sync_jobs_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_sync_jobs_parent ON public.marketplace_sync_jobs USING btree (parent_job_id);


--
-- Name: idx_sync_jobs_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_sync_jobs_priority ON public.marketplace_sync_jobs USING btree (priority);


--
-- Name: idx_tenant_activity_log_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_activity_log_action ON public.tenant_activity_log USING btree (action);


--
-- Name: idx_tenant_activity_log_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_activity_log_created_at ON public.tenant_activity_log USING btree (created_at);


--
-- Name: idx_tenant_activity_log_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_activity_log_tenant_id ON public.tenant_activity_log USING btree (tenant_id);


--
-- Name: idx_tenant_activity_log_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_activity_log_user_id ON public.tenant_activity_log USING btree (user_id);


--
-- Name: idx_tenant_auth_audit_log_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_auth_audit_log_created_at ON public.tenant_auth_audit_log USING btree (created_at);


--
-- Name: idx_tenant_auth_audit_log_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_auth_audit_log_event_type ON public.tenant_auth_audit_log USING btree (event_type);


--
-- Name: idx_tenant_auth_audit_log_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_auth_audit_log_tenant_id ON public.tenant_auth_audit_log USING btree (tenant_id);


--
-- Name: idx_tenant_auth_audit_log_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_auth_audit_log_user_id ON public.tenant_auth_audit_log USING btree (user_id);


--
-- Name: idx_tenant_auth_policies_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_auth_policies_tenant_id ON public.tenant_auth_policies USING btree (tenant_id);


--
-- Name: idx_tenant_credentials_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_credentials_tenant_id ON public.tenant_credentials USING btree (tenant_id);


--
-- Name: idx_tenant_credentials_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_credentials_user_id ON public.tenant_credentials USING btree (user_id);


--
-- Name: idx_tenant_host_admin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_admin ON public.tenant_host_records USING btree (admin_host);


--
-- Name: idx_tenant_host_api; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_api ON public.tenant_host_records USING btree (api_host);


--
-- Name: idx_tenant_host_records_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_records_deleted_at ON public.tenant_host_records USING btree (deleted_at);


--
-- Name: idx_tenant_host_retry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_retry ON public.tenant_host_records USING btree (status, retry_count, last_retry_at) WHERE ((status)::text = 'failed'::text);


--
-- Name: idx_tenant_host_slug_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_slug_lookup ON public.tenant_host_records USING btree (slug);


--
-- Name: idx_tenant_host_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_status ON public.tenant_host_records USING btree (status);


--
-- Name: idx_tenant_host_status_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_status_created ON public.tenant_host_records USING btree (status, created_at DESC);


--
-- Name: idx_tenant_host_storefront; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_storefront ON public.tenant_host_records USING btree (storefront_host);


--
-- Name: idx_tenant_host_storefront_www; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_storefront_www ON public.tenant_host_records USING btree (storefront_www_host);


--
-- Name: idx_tenant_host_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_host_tenant_id ON public.tenant_host_records USING btree (tenant_id);


--
-- Name: idx_tenant_slug_reservations_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_slug_reservations_expires_at ON public.tenant_slug_reservations USING btree (expires_at);


--
-- Name: idx_tenant_slug_reservations_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_slug_reservations_session_id ON public.tenant_slug_reservations USING btree (session_id);


--
-- Name: idx_tenant_slug_reservations_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_slug_reservations_tenant_id ON public.tenant_slug_reservations USING btree (tenant_id);


--
-- Name: idx_tenant_users_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_users_email ON public.tenant_users USING btree (email);


--
-- Name: idx_tenant_users_keycloak_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_users_keycloak_id ON public.tenant_users USING btree (keycloak_id);


--
-- Name: idx_tenant_users_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_users_status ON public.tenant_users USING btree (status);


--
-- Name: idx_tenants_business_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenants_business_model ON public.tenants USING btree (business_model);


--
-- Name: idx_tenants_keycloak_org_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenants_keycloak_org_id ON public.tenants USING btree (keycloak_org_id);


--
-- Name: idx_tenants_owner_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenants_owner_user_id ON public.tenants USING btree (owner_user_id);


--
-- Name: idx_tenants_pricing_tier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenants_pricing_tier ON public.tenants USING btree (pricing_tier);


--
-- Name: idx_tenants_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenants_status ON public.tenants USING btree (status);


--
-- Name: idx_user_tenant_memberships_invitation_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_user_tenant_memberships_invitation_token ON public.user_tenant_memberships USING btree (invitation_token);


--
-- Name: idx_user_tenant_memberships_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_user_tenant_memberships_tenant_id ON public.user_tenant_memberships USING btree (tenant_id);


--
-- Name: idx_user_tenant_memberships_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_user_tenant_memberships_user_id ON public.user_tenant_memberships USING btree (user_id);


--
-- Name: idx_verification_attempts_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_attempts_deleted_at ON public.verification_attempts USING btree (deleted_at);


--
-- Name: idx_verification_attempts_verification_code_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_attempts_verification_code_id ON public.verification_attempts USING btree (verification_code_id);


--
-- Name: idx_verification_codes_code_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_codes_code_hash ON public.verification_codes USING btree (code_hash);


--
-- Name: idx_verification_codes_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_codes_deleted_at ON public.verification_codes USING btree (deleted_at);


--
-- Name: idx_verification_codes_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_codes_expires_at ON public.verification_codes USING btree (expires_at);


--
-- Name: idx_verification_codes_is_used; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_codes_is_used ON public.verification_codes USING btree (is_used);


--
-- Name: idx_verification_codes_recipient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_codes_recipient ON public.verification_codes USING btree (recipient);


--
-- Name: idx_verification_codes_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_codes_session_id ON public.verification_codes USING btree (session_id);


--
-- Name: idx_verification_codes_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_codes_tenant_id ON public.verification_codes USING btree (tenant_id);


--
-- Name: idx_verification_codes_verified_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_codes_verified_at ON public.verification_codes USING btree (verified_at);


--
-- Name: idx_verification_records_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_records_expires_at ON public.verification_records USING btree (expires_at);


--
-- Name: idx_verification_records_onboarding_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_records_onboarding_session_id ON public.verification_records USING btree (onboarding_session_id);


--
-- Name: idx_verification_type_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_verification_type_status ON public.verification_records USING btree (verification_type, status);


--
-- Name: idx_webhook_events_next_retry_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_webhook_events_next_retry_at ON public.webhook_events USING btree (next_retry_at);


--
-- Name: idx_webhook_events_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_webhook_events_status ON public.webhook_events USING btree (status);


--
-- Name: idx_webhooks_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_webhooks_created ON public.payment_webhook_events USING btree (created_at);


--
-- Name: idx_webhooks_gateway; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_webhooks_gateway ON public.payment_webhook_events USING btree (tenant_id, gateway_type);


--
-- Name: idx_webhooks_processed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_webhooks_processed ON public.payment_webhook_events USING btree (processed);


--
-- Name: idx_webhooks_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_webhooks_type ON public.payment_webhook_events USING btree (event_type);


--
-- Name: address_cache address_cache_updated_trigger; Type: TRIGGER; Schema: location; Owner: -
--

CREATE TRIGGER address_cache_updated_trigger BEFORE UPDATE ON location.address_cache FOR EACH ROW EXECUTE FUNCTION location.address_cache_updated_at();


--
-- Name: places places_geohash_trigger; Type: TRIGGER; Schema: location; Owner: -
--

CREATE TRIGGER places_geohash_trigger BEFORE INSERT OR UPDATE OF latitude, longitude ON location.places FOR EACH ROW EXECUTE FUNCTION location.places_geohash_update();


--
-- Name: places places_search_vector_trigger; Type: TRIGGER; Schema: location; Owner: -
--

CREATE TRIGGER places_search_vector_trigger BEFORE INSERT OR UPDATE ON location.places FOR EACH ROW EXECUTE FUNCTION location.places_search_vector_update();


--
-- Name: places fk_places_country; Type: FK CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.places
    ADD CONSTRAINT fk_places_country FOREIGN KEY (country_code) REFERENCES location.countries(id) ON DELETE SET NULL;


--
-- Name: location_cache location_cache_country_id_fkey; Type: FK CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.location_cache
    ADD CONSTRAINT location_cache_country_id_fkey FOREIGN KEY (country_id) REFERENCES location.countries(id);


--
-- Name: location_cache location_cache_state_id_fkey; Type: FK CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.location_cache
    ADD CONSTRAINT location_cache_state_id_fkey FOREIGN KEY (state_id) REFERENCES location.states(id);


--
-- Name: location_cache location_cache_timezone_id_fkey; Type: FK CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.location_cache
    ADD CONSTRAINT location_cache_timezone_id_fkey FOREIGN KEY (timezone_id) REFERENCES location.timezones(id);


--
-- Name: states states_country_id_fkey; Type: FK CONSTRAINT; Schema: location; Owner: -
--

ALTER TABLE ONLY location.states
    ADD CONSTRAINT states_country_id_fkey FOREIGN KEY (country_id) REFERENCES location.countries(id);


--
-- Name: ad_billing_invoices fk_ad_billing_invoices_payment_transaction; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_billing_invoices
    ADD CONSTRAINT fk_ad_billing_invoices_payment_transaction FOREIGN KEY (payment_transaction_id) REFERENCES public.payment_transactions(id);


--
-- Name: ad_campaign_payments fk_ad_campaign_payments_commission_tier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_campaign_payments
    ADD CONSTRAINT fk_ad_campaign_payments_commission_tier FOREIGN KEY (commission_tier_id) REFERENCES public.ad_commission_tiers(id);


--
-- Name: ad_campaign_payments fk_ad_campaign_payments_payment_transaction; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_campaign_payments
    ADD CONSTRAINT fk_ad_campaign_payments_payment_transaction FOREIGN KEY (payment_transaction_id) REFERENCES public.payment_transactions(id);


--
-- Name: ad_revenue_ledger fk_ad_revenue_ledger_campaign_payment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_revenue_ledger
    ADD CONSTRAINT fk_ad_revenue_ledger_campaign_payment FOREIGN KEY (campaign_payment_id) REFERENCES public.ad_campaign_payments(id);


--
-- Name: ad_revenue_ledger fk_ad_revenue_ledger_invoice; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_revenue_ledger
    ADD CONSTRAINT fk_ad_revenue_ledger_invoice FOREIGN KEY (invoice_id) REFERENCES public.ad_billing_invoices(id);


--
-- Name: ad_revenue_ledger fk_ad_revenue_ledger_payment_transaction; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ad_revenue_ledger
    ADD CONSTRAINT fk_ad_revenue_ledger_payment_transaction FOREIGN KEY (payment_transaction_id) REFERENCES public.payment_transactions(id);


--
-- Name: marketplace_credentials fk_marketplace_connections_credentials; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_credentials
    ADD CONSTRAINT fk_marketplace_connections_credentials FOREIGN KEY (connection_id) REFERENCES public.marketplace_connections(id);


--
-- Name: marketplace_sync_jobs fk_marketplace_connections_sync_jobs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_sync_jobs
    ADD CONSTRAINT fk_marketplace_connections_sync_jobs FOREIGN KEY (connection_id) REFERENCES public.marketplace_connections(id);


--
-- Name: marketplace_inventory_mappings fk_marketplace_inventory_mappings_connection; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_inventory_mappings
    ADD CONSTRAINT fk_marketplace_inventory_mappings_connection FOREIGN KEY (connection_id) REFERENCES public.marketplace_connections(id);


--
-- Name: marketplace_order_mappings fk_marketplace_order_mappings_connection; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_order_mappings
    ADD CONSTRAINT fk_marketplace_order_mappings_connection FOREIGN KEY (connection_id) REFERENCES public.marketplace_connections(id);


--
-- Name: marketplace_product_mappings fk_marketplace_product_mappings_connection; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_product_mappings
    ADD CONSTRAINT fk_marketplace_product_mappings_connection FOREIGN KEY (connection_id) REFERENCES public.marketplace_connections(id);


--
-- Name: marketplace_sync_logs fk_marketplace_sync_jobs_logs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_sync_logs
    ADD CONSTRAINT fk_marketplace_sync_jobs_logs FOREIGN KEY (sync_job_id) REFERENCES public.marketplace_sync_jobs(id);


--
-- Name: marketplace_sync_jobs fk_marketplace_sync_jobs_parent_job; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketplace_sync_jobs
    ADD CONSTRAINT fk_marketplace_sync_jobs_parent_job FOREIGN KEY (parent_job_id) REFERENCES public.marketplace_sync_jobs(id);


--
-- Name: application_configurations fk_onboarding_sessions_application_configurations; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.application_configurations
    ADD CONSTRAINT fk_onboarding_sessions_application_configurations FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: business_addresses fk_onboarding_sessions_business_addresses; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_addresses
    ADD CONSTRAINT fk_onboarding_sessions_business_addresses FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: business_informations fk_onboarding_sessions_business_information; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_informations
    ADD CONSTRAINT fk_onboarding_sessions_business_information FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: contact_informations fk_onboarding_sessions_contact_information; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_informations
    ADD CONSTRAINT fk_onboarding_sessions_contact_information FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: domain_reservations fk_onboarding_sessions_domain_reservations; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.domain_reservations
    ADD CONSTRAINT fk_onboarding_sessions_domain_reservations FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: onboarding_notifications fk_onboarding_sessions_notifications; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_notifications
    ADD CONSTRAINT fk_onboarding_sessions_notifications FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: payment_informations fk_onboarding_sessions_payment_information; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_informations
    ADD CONSTRAINT fk_onboarding_sessions_payment_information FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: onboarding_tasks fk_onboarding_sessions_tasks; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_tasks
    ADD CONSTRAINT fk_onboarding_sessions_tasks FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: onboarding_sessions fk_onboarding_sessions_template; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.onboarding_sessions
    ADD CONSTRAINT fk_onboarding_sessions_template FOREIGN KEY (template_id) REFERENCES public.onboarding_templates(id);


--
-- Name: verification_records fk_onboarding_sessions_verification_records; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.verification_records
    ADD CONSTRAINT fk_onboarding_sessions_verification_records FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: task_execution_logs fk_onboarding_tasks_execution_logs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_execution_logs
    ADD CONSTRAINT fk_onboarding_tasks_execution_logs FOREIGN KEY (onboarding_task_id) REFERENCES public.onboarding_tasks(id);


--
-- Name: payment_disputes fk_payment_disputes_payment_transaction; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_disputes
    ADD CONSTRAINT fk_payment_disputes_payment_transaction FOREIGN KEY (payment_transaction_id) REFERENCES public.payment_transactions(id);


--
-- Name: payment_gateway_regions fk_payment_gateway_configs_regions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_gateway_regions
    ADD CONSTRAINT fk_payment_gateway_configs_regions FOREIGN KEY (gateway_config_id) REFERENCES public.payment_gateway_configs(id);


--
-- Name: platform_fee_ledger fk_payment_transactions_fee_ledger_entries; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_fee_ledger
    ADD CONSTRAINT fk_payment_transactions_fee_ledger_entries FOREIGN KEY (payment_transaction_id) REFERENCES public.payment_transactions(id);


--
-- Name: payment_transactions fk_payment_transactions_gateway_config; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_transactions
    ADD CONSTRAINT fk_payment_transactions_gateway_config FOREIGN KEY (gateway_config_id) REFERENCES public.payment_gateway_configs(id);


--
-- Name: refund_transactions fk_payment_transactions_refunds; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refund_transactions
    ADD CONSTRAINT fk_payment_transactions_refunds FOREIGN KEY (payment_transaction_id) REFERENCES public.payment_transactions(id);


--
-- Name: platform_fee_ledger fk_refund_transactions_fee_ledger_entries; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_fee_ledger
    ADD CONSTRAINT fk_refund_transactions_fee_ledger_entries FOREIGN KEY (refund_transaction_id) REFERENCES public.refund_transactions(id);


--
-- Name: saved_payment_methods fk_saved_payment_methods_gateway_config; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.saved_payment_methods
    ADD CONSTRAINT fk_saved_payment_methods_gateway_config FOREIGN KEY (gateway_config_id) REFERENCES public.payment_gateway_configs(id);


--
-- Name: shipment_trackings fk_shipments_tracking; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipment_trackings
    ADD CONSTRAINT fk_shipments_tracking FOREIGN KEY (shipment_id) REFERENCES public.shipments(id);


--
-- Name: shipping_carrier_regions fk_shipping_carrier_configs_regions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipping_carrier_regions
    ADD CONSTRAINT fk_shipping_carrier_configs_regions FOREIGN KEY (carrier_config_id) REFERENCES public.shipping_carrier_configs(id);


--
-- Name: tenant_auth_policies fk_tenant_auth_policies_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_auth_policies
    ADD CONSTRAINT fk_tenant_auth_policies_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: tenant_credentials fk_tenant_credentials_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_credentials
    ADD CONSTRAINT fk_tenant_credentials_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: user_tenant_memberships fk_tenant_users_memberships; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tenant_memberships
    ADD CONSTRAINT fk_tenant_users_memberships FOREIGN KEY (user_id) REFERENCES public.tenant_users(id);


--
-- Name: user_tenant_memberships fk_tenants_memberships; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tenant_memberships
    ADD CONSTRAINT fk_tenants_memberships FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- PostgreSQL database dump complete
--


