--
-- PostgreSQL database dump
--

\restrict WZBWdbl3JSzWfrbhB1vmf6XspOxAD1zmtgjBBqzajtJVegfbiKC8uU4jmwz93PV

-- Dumped from database version 16.13
-- Dumped by pg_dump version 16.13

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
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: application_configurations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.application_configurations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_session_id uuid NOT NULL,
    application_type text NOT NULL,
    configuration_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


ALTER TABLE public.application_configurations OWNER TO postgres;

--
-- Name: business_addresses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.business_addresses (
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


ALTER TABLE public.business_addresses OWNER TO postgres;

--
-- Name: business_informations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.business_informations (
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


ALTER TABLE public.business_informations OWNER TO postgres;

--
-- Name: contact_informations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.contact_informations (
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


ALTER TABLE public.contact_informations OWNER TO postgres;

--
-- Name: deactivated_memberships; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.deactivated_memberships (
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


ALTER TABLE public.deactivated_memberships OWNER TO postgres;

--
-- Name: deleted_tenants; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.deleted_tenants (
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


ALTER TABLE public.deleted_tenants OWNER TO postgres;

--
-- Name: domain_reservations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.domain_reservations (
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


ALTER TABLE public.domain_reservations OWNER TO postgres;

--
-- Name: onboarding_notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.onboarding_notifications (
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


ALTER TABLE public.onboarding_notifications OWNER TO postgres;

--
-- Name: onboarding_sessions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.onboarding_sessions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id uuid,
    template_id uuid NOT NULL,
    application_type text NOT NULL,
    status text DEFAULT 'started'::text,
    current_step text,
    completed_steps jsonb DEFAULT '[]'::jsonb,
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


ALTER TABLE public.onboarding_sessions OWNER TO postgres;

--
-- Name: onboarding_tasks; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.onboarding_tasks (
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


ALTER TABLE public.onboarding_tasks OWNER TO postgres;

--
-- Name: onboarding_templates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.onboarding_templates (
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


ALTER TABLE public.onboarding_templates OWNER TO postgres;

--
-- Name: passkey_credentials; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.passkey_credentials (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    credential_id text NOT NULL,
    public_key text NOT NULL,
    counter bigint DEFAULT 0,
    device_type character varying(50),
    backed_up boolean DEFAULT false,
    transports jsonb DEFAULT '[]'::jsonb,
    name character varying(255),
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    last_used_at timestamp with time zone
);


ALTER TABLE public.passkey_credentials OWNER TO postgres;

--
-- Name: password_reset_tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.password_reset_tokens (
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


ALTER TABLE public.password_reset_tokens OWNER TO postgres;

--
-- Name: payment_informations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_informations (
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


ALTER TABLE public.payment_informations OWNER TO postgres;

--
-- Name: reserved_slugs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.reserved_slugs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    slug character varying(50) NOT NULL,
    reason character varying(255) NOT NULL,
    category character varying(50) DEFAULT 'system'::character varying NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    created_by character varying(255),
    updated_at timestamp with time zone
);


ALTER TABLE public.reserved_slugs OWNER TO postgres;

--
-- Name: task_execution_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.task_execution_logs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    onboarding_task_id uuid NOT NULL,
    action text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb,
    error_message text,
    performed_by text NOT NULL,
    created_at timestamp with time zone
);


ALTER TABLE public.task_execution_logs OWNER TO postgres;

--
-- Name: tenant_activity_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tenant_activity_log (
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


ALTER TABLE public.tenant_activity_log OWNER TO postgres;

--
-- Name: tenant_auth_audit_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tenant_auth_audit_log (
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


ALTER TABLE public.tenant_auth_audit_log OWNER TO postgres;

--
-- Name: tenant_auth_policies; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tenant_auth_policies (
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
    enable_progressive_lockout boolean DEFAULT true,
    tier1_lockout_minutes bigint DEFAULT 30,
    permanent_lockout_threshold bigint DEFAULT 7,
    lockout_reset_hours bigint DEFAULT 24,
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
    updated_by uuid
);


ALTER TABLE public.tenant_auth_policies OWNER TO postgres;

--
-- Name: tenant_credentials; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tenant_credentials (
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
    lockout_count bigint DEFAULT 0,
    current_tier bigint DEFAULT 0,
    permanently_locked boolean DEFAULT false,
    permanent_locked_at timestamp with time zone,
    unlocked_by uuid,
    unlocked_at timestamp with time zone,
    total_failed_attempts bigint DEFAULT 0,
    active_sessions bigint DEFAULT 0,
    max_sessions bigint DEFAULT 5,
    password_history jsonb DEFAULT '[]'::jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    created_by uuid,
    updated_by uuid
);


ALTER TABLE public.tenant_credentials OWNER TO postgres;

--
-- Name: tenant_slug_reservations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tenant_slug_reservations (
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


ALTER TABLE public.tenant_slug_reservations OWNER TO postgres;

--
-- Name: tenant_users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tenant_users (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    idp_id character varying(255),
    email text NOT NULL,
    first_name text NOT NULL,
    last_name text NOT NULL,
    phone text,
    status text DEFAULT 'active'::text,
    password text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


ALTER TABLE public.tenant_users OWNER TO postgres;

--
-- Name: tenants; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tenants (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name text NOT NULL,
    slug character varying(50) NOT NULL,
    subdomain text NOT NULL,
    display_name character varying(255),
    logo_url text,
    favicon_url text,
    business_type text,
    industry text,
    status text DEFAULT 'creating'::text,
    mode text DEFAULT 'development'::text,
    admin_url character varying(255),
    storefront_url character varying(255),
    api_url character varying(255),
    use_custom_domain boolean DEFAULT false,
    custom_domain character varying(255),
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
    idp_org_id uuid,
    growth_book_org_id character varying(255),
    growth_book_sdk_key character varying(255),
    growth_book_admin_key character varying(255),
    growth_book_enabled boolean DEFAULT false,
    growth_book_provisioned_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


ALTER TABLE public.tenants OWNER TO postgres;

--
-- Name: user_tenant_memberships; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_tenant_memberships (
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


ALTER TABLE public.user_tenant_memberships OWNER TO postgres;

--
-- Name: verification_records; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.verification_records (
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


ALTER TABLE public.verification_records OWNER TO postgres;

--
-- Name: verification_tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.verification_tokens (
    token character varying(255) NOT NULL,
    session_id uuid NOT NULL,
    email character varying(255) NOT NULL,
    purpose character varying(64) DEFAULT 'email_verification'::character varying NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    created_at timestamp with time zone
);


ALTER TABLE public.verification_tokens OWNER TO postgres;

--
-- Name: webhook_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.webhook_events (
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


ALTER TABLE public.webhook_events OWNER TO postgres;

--
-- Name: application_configurations application_configurations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.application_configurations
    ADD CONSTRAINT application_configurations_pkey PRIMARY KEY (id);


--
-- Name: business_addresses business_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_addresses
    ADD CONSTRAINT business_addresses_pkey PRIMARY KEY (id);


--
-- Name: business_informations business_informations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_informations
    ADD CONSTRAINT business_informations_pkey PRIMARY KEY (id);


--
-- Name: contact_informations contact_informations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_informations
    ADD CONSTRAINT contact_informations_pkey PRIMARY KEY (id);


--
-- Name: deactivated_memberships deactivated_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deactivated_memberships
    ADD CONSTRAINT deactivated_memberships_pkey PRIMARY KEY (id);


--
-- Name: deleted_tenants deleted_tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.deleted_tenants
    ADD CONSTRAINT deleted_tenants_pkey PRIMARY KEY (id);


--
-- Name: domain_reservations domain_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.domain_reservations
    ADD CONSTRAINT domain_reservations_pkey PRIMARY KEY (id);


--
-- Name: onboarding_notifications onboarding_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.onboarding_notifications
    ADD CONSTRAINT onboarding_notifications_pkey PRIMARY KEY (id);


--
-- Name: onboarding_sessions onboarding_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.onboarding_sessions
    ADD CONSTRAINT onboarding_sessions_pkey PRIMARY KEY (id);


--
-- Name: onboarding_tasks onboarding_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.onboarding_tasks
    ADD CONSTRAINT onboarding_tasks_pkey PRIMARY KEY (id);


--
-- Name: onboarding_templates onboarding_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.onboarding_templates
    ADD CONSTRAINT onboarding_templates_pkey PRIMARY KEY (id);


--
-- Name: passkey_credentials passkey_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.passkey_credentials
    ADD CONSTRAINT passkey_credentials_pkey PRIMARY KEY (id);


--
-- Name: password_reset_tokens password_reset_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_pkey PRIMARY KEY (id);


--
-- Name: payment_informations payment_informations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_informations
    ADD CONSTRAINT payment_informations_pkey PRIMARY KEY (id);


--
-- Name: reserved_slugs reserved_slugs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reserved_slugs
    ADD CONSTRAINT reserved_slugs_pkey PRIMARY KEY (id);


--
-- Name: task_execution_logs task_execution_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.task_execution_logs
    ADD CONSTRAINT task_execution_logs_pkey PRIMARY KEY (id);


--
-- Name: tenant_activity_log tenant_activity_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_activity_log
    ADD CONSTRAINT tenant_activity_log_pkey PRIMARY KEY (id);


--
-- Name: tenant_auth_audit_log tenant_auth_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_auth_audit_log
    ADD CONSTRAINT tenant_auth_audit_log_pkey PRIMARY KEY (id);


--
-- Name: tenant_auth_policies tenant_auth_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_auth_policies
    ADD CONSTRAINT tenant_auth_policies_pkey PRIMARY KEY (id);


--
-- Name: tenant_credentials tenant_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_credentials
    ADD CONSTRAINT tenant_credentials_pkey PRIMARY KEY (id);


--
-- Name: tenant_slug_reservations tenant_slug_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_slug_reservations
    ADD CONSTRAINT tenant_slug_reservations_pkey PRIMARY KEY (id);


--
-- Name: tenant_users tenant_users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_users
    ADD CONSTRAINT tenant_users_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: domain_reservations uni_domain_reservations_domain_value; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.domain_reservations
    ADD CONSTRAINT uni_domain_reservations_domain_value UNIQUE (domain_value);


--
-- Name: reserved_slugs uni_reserved_slugs_slug; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reserved_slugs
    ADD CONSTRAINT uni_reserved_slugs_slug UNIQUE (slug);


--
-- Name: tenant_auth_policies uni_tenant_auth_policies_tenant_id; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_auth_policies
    ADD CONSTRAINT uni_tenant_auth_policies_tenant_id UNIQUE (tenant_id);


--
-- Name: tenant_slug_reservations uni_tenant_slug_reservations_slug; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_slug_reservations
    ADD CONSTRAINT uni_tenant_slug_reservations_slug UNIQUE (slug);


--
-- Name: tenant_users uni_tenant_users_email; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_users
    ADD CONSTRAINT uni_tenant_users_email UNIQUE (email);


--
-- Name: tenants uni_tenants_slug; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT uni_tenants_slug UNIQUE (slug);


--
-- Name: tenants uni_tenants_subdomain; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT uni_tenants_subdomain UNIQUE (subdomain);


--
-- Name: user_tenant_memberships user_tenant_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_tenant_memberships
    ADD CONSTRAINT user_tenant_memberships_pkey PRIMARY KEY (id);


--
-- Name: verification_records verification_records_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.verification_records
    ADD CONSTRAINT verification_records_pkey PRIMARY KEY (id);


--
-- Name: verification_tokens verification_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.verification_tokens
    ADD CONSTRAINT verification_tokens_pkey PRIMARY KEY (token);


--
-- Name: webhook_events webhook_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.webhook_events
    ADD CONSTRAINT webhook_events_pkey PRIMARY KEY (id);


--
-- Name: idx_application_configurations_onboarding_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_application_configurations_onboarding_session_id ON public.application_configurations USING btree (onboarding_session_id);


--
-- Name: idx_business_addresses_onboarding_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_business_addresses_onboarding_session_id ON public.business_addresses USING btree (onboarding_session_id);


--
-- Name: idx_business_informations_onboarding_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_business_informations_onboarding_session_id ON public.business_informations USING btree (onboarding_session_id);


--
-- Name: idx_business_informations_tenant_slug; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_business_informations_tenant_slug ON public.business_informations USING btree (tenant_slug);


--
-- Name: idx_contact_informations_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_contact_informations_email ON public.contact_informations USING btree (email);


--
-- Name: idx_contact_informations_onboarding_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_contact_informations_onboarding_session_id ON public.contact_informations USING btree (onboarding_session_id);


--
-- Name: idx_deactivated_memberships_deactivated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deactivated_memberships_deactivated_at ON public.deactivated_memberships USING btree (deactivated_at);


--
-- Name: idx_deactivated_memberships_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deactivated_memberships_email ON public.deactivated_memberships USING btree (email);


--
-- Name: idx_deactivated_memberships_is_purged; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deactivated_memberships_is_purged ON public.deactivated_memberships USING btree (is_purged);


--
-- Name: idx_deactivated_memberships_original_membership_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deactivated_memberships_original_membership_id ON public.deactivated_memberships USING btree (original_membership_id);


--
-- Name: idx_deactivated_memberships_scheduled_purge_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deactivated_memberships_scheduled_purge_at ON public.deactivated_memberships USING btree (scheduled_purge_at);


--
-- Name: idx_deactivated_memberships_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deactivated_memberships_tenant_id ON public.deactivated_memberships USING btree (tenant_id);


--
-- Name: idx_deactivated_memberships_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deactivated_memberships_user_id ON public.deactivated_memberships USING btree (user_id);


--
-- Name: idx_deleted_tenants_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deleted_tenants_deleted_at ON public.deleted_tenants USING btree (deleted_at);


--
-- Name: idx_deleted_tenants_deleted_by_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deleted_tenants_deleted_by_user_id ON public.deleted_tenants USING btree (deleted_by_user_id);


--
-- Name: idx_deleted_tenants_original_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deleted_tenants_original_tenant_id ON public.deleted_tenants USING btree (original_tenant_id);


--
-- Name: idx_deleted_tenants_owner_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deleted_tenants_owner_email ON public.deleted_tenants USING btree (owner_email);


--
-- Name: idx_deleted_tenants_slug; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_deleted_tenants_slug ON public.deleted_tenants USING btree (slug);


--
-- Name: idx_domain_reservations_domain_value; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_domain_reservations_domain_value ON public.domain_reservations USING btree (domain_value);


--
-- Name: idx_domain_reservations_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_domain_reservations_status ON public.domain_reservations USING btree (status);


--
-- Name: idx_onboarding_notifications_onboarding_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_notifications_onboarding_session_id ON public.onboarding_notifications USING btree (onboarding_session_id);


--
-- Name: idx_onboarding_notifications_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_notifications_status ON public.onboarding_notifications USING btree (status);


--
-- Name: idx_onboarding_sessions_application_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_sessions_application_type ON public.onboarding_sessions USING btree (application_type);


--
-- Name: idx_onboarding_sessions_business_model; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_sessions_business_model ON public.onboarding_sessions USING btree (business_model);


--
-- Name: idx_onboarding_sessions_current_step; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_sessions_current_step ON public.onboarding_sessions USING btree (current_step);


--
-- Name: idx_onboarding_sessions_draft_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_sessions_draft_expires_at ON public.onboarding_sessions USING btree (draft_expires_at);


--
-- Name: idx_onboarding_sessions_draft_saved_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_sessions_draft_saved_at ON public.onboarding_sessions USING btree (draft_saved_at);


--
-- Name: idx_onboarding_sessions_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_sessions_expires_at ON public.onboarding_sessions USING btree (expires_at);


--
-- Name: idx_onboarding_sessions_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_sessions_status ON public.onboarding_sessions USING btree (status);


--
-- Name: idx_onboarding_sessions_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_sessions_tenant_id ON public.onboarding_sessions USING btree (tenant_id);


--
-- Name: idx_onboarding_tasks_onboarding_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_tasks_onboarding_session_id ON public.onboarding_tasks USING btree (onboarding_session_id);


--
-- Name: idx_onboarding_tasks_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_onboarding_tasks_status ON public.onboarding_tasks USING btree (status);


--
-- Name: idx_passkey_credentials_credential_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_passkey_credentials_credential_id ON public.passkey_credentials USING btree (credential_id);


--
-- Name: idx_passkey_credentials_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_passkey_credentials_tenant_id ON public.passkey_credentials USING btree (tenant_id);


--
-- Name: idx_passkey_credentials_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_passkey_credentials_user_id ON public.passkey_credentials USING btree (user_id);


--
-- Name: idx_password_reset_tokens_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_password_reset_tokens_email ON public.password_reset_tokens USING btree (email);


--
-- Name: idx_password_reset_tokens_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_password_reset_tokens_expires_at ON public.password_reset_tokens USING btree (expires_at);


--
-- Name: idx_password_reset_tokens_is_used; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_password_reset_tokens_is_used ON public.password_reset_tokens USING btree (is_used);


--
-- Name: idx_password_reset_tokens_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_password_reset_tokens_tenant_id ON public.password_reset_tokens USING btree (tenant_id);


--
-- Name: idx_password_reset_tokens_token; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_password_reset_tokens_token ON public.password_reset_tokens USING btree (token);


--
-- Name: idx_password_reset_tokens_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_password_reset_tokens_user_id ON public.password_reset_tokens USING btree (user_id);


--
-- Name: idx_payment_informations_onboarding_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_payment_informations_onboarding_session_id ON public.payment_informations USING btree (onboarding_session_id);


--
-- Name: idx_payment_informations_payment_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_payment_informations_payment_status ON public.payment_informations USING btree (payment_status);


--
-- Name: idx_tenant_activity_log_action; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_activity_log_action ON public.tenant_activity_log USING btree (action);


--
-- Name: idx_tenant_activity_log_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_activity_log_created_at ON public.tenant_activity_log USING btree (created_at);


--
-- Name: idx_tenant_activity_log_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_activity_log_tenant_id ON public.tenant_activity_log USING btree (tenant_id);


--
-- Name: idx_tenant_activity_log_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_activity_log_user_id ON public.tenant_activity_log USING btree (user_id);


--
-- Name: idx_tenant_auth_audit_log_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_auth_audit_log_created_at ON public.tenant_auth_audit_log USING btree (created_at);


--
-- Name: idx_tenant_auth_audit_log_event_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_auth_audit_log_event_type ON public.tenant_auth_audit_log USING btree (event_type);


--
-- Name: idx_tenant_auth_audit_log_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_auth_audit_log_tenant_id ON public.tenant_auth_audit_log USING btree (tenant_id);


--
-- Name: idx_tenant_auth_audit_log_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_auth_audit_log_user_id ON public.tenant_auth_audit_log USING btree (user_id);


--
-- Name: idx_tenant_auth_policies_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_auth_policies_tenant_id ON public.tenant_auth_policies USING btree (tenant_id);


--
-- Name: idx_tenant_credentials_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_credentials_tenant_id ON public.tenant_credentials USING btree (tenant_id);


--
-- Name: idx_tenant_credentials_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_credentials_user_id ON public.tenant_credentials USING btree (user_id);


--
-- Name: idx_tenant_slug_reservations_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_slug_reservations_expires_at ON public.tenant_slug_reservations USING btree (expires_at);


--
-- Name: idx_tenant_slug_reservations_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_slug_reservations_session_id ON public.tenant_slug_reservations USING btree (session_id);


--
-- Name: idx_tenant_slug_reservations_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_slug_reservations_tenant_id ON public.tenant_slug_reservations USING btree (tenant_id);


--
-- Name: idx_tenant_users_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_users_email ON public.tenant_users USING btree (email);


--
-- Name: idx_tenant_users_id_p_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_users_id_p_id ON public.tenant_users USING btree (idp_id);


--
-- Name: idx_tenant_users_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenant_users_status ON public.tenant_users USING btree (status);


--
-- Name: idx_tenants_business_model; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenants_business_model ON public.tenants USING btree (business_model);


--
-- Name: idx_tenants_id_p_org_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenants_id_p_org_id ON public.tenants USING btree (idp_org_id);


--
-- Name: idx_tenants_owner_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenants_owner_user_id ON public.tenants USING btree (owner_user_id);


--
-- Name: idx_tenants_pricing_tier; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenants_pricing_tier ON public.tenants USING btree (pricing_tier);


--
-- Name: idx_tenants_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tenants_status ON public.tenants USING btree (status);


--
-- Name: idx_user_tenant_memberships_invitation_token; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_tenant_memberships_invitation_token ON public.user_tenant_memberships USING btree (invitation_token);


--
-- Name: idx_user_tenant_memberships_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_tenant_memberships_tenant_id ON public.user_tenant_memberships USING btree (tenant_id);


--
-- Name: idx_user_tenant_memberships_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_tenant_memberships_user_id ON public.user_tenant_memberships USING btree (user_id);


--
-- Name: idx_verification_records_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_verification_records_expires_at ON public.verification_records USING btree (expires_at);


--
-- Name: idx_verification_records_onboarding_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_verification_records_onboarding_session_id ON public.verification_records USING btree (onboarding_session_id);


--
-- Name: idx_verification_tokens_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_verification_tokens_email ON public.verification_tokens USING btree (email);


--
-- Name: idx_verification_tokens_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_verification_tokens_expires_at ON public.verification_tokens USING btree (expires_at);


--
-- Name: idx_verification_tokens_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_verification_tokens_session_id ON public.verification_tokens USING btree (session_id);


--
-- Name: idx_verification_type_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_verification_type_status ON public.verification_records USING btree (verification_type, status);


--
-- Name: idx_webhook_events_next_retry_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_webhook_events_next_retry_at ON public.webhook_events USING btree (next_retry_at);


--
-- Name: idx_webhook_events_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_webhook_events_status ON public.webhook_events USING btree (status);


--
-- Name: application_configurations fk_onboarding_sessions_application_configurations; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.application_configurations
    ADD CONSTRAINT fk_onboarding_sessions_application_configurations FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: business_addresses fk_onboarding_sessions_business_addresses; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_addresses
    ADD CONSTRAINT fk_onboarding_sessions_business_addresses FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: business_informations fk_onboarding_sessions_business_information; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_informations
    ADD CONSTRAINT fk_onboarding_sessions_business_information FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: contact_informations fk_onboarding_sessions_contact_information; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_informations
    ADD CONSTRAINT fk_onboarding_sessions_contact_information FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: domain_reservations fk_onboarding_sessions_domain_reservations; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.domain_reservations
    ADD CONSTRAINT fk_onboarding_sessions_domain_reservations FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: onboarding_notifications fk_onboarding_sessions_notifications; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.onboarding_notifications
    ADD CONSTRAINT fk_onboarding_sessions_notifications FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: payment_informations fk_onboarding_sessions_payment_information; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_informations
    ADD CONSTRAINT fk_onboarding_sessions_payment_information FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: onboarding_tasks fk_onboarding_sessions_tasks; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.onboarding_tasks
    ADD CONSTRAINT fk_onboarding_sessions_tasks FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: onboarding_sessions fk_onboarding_sessions_template; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.onboarding_sessions
    ADD CONSTRAINT fk_onboarding_sessions_template FOREIGN KEY (template_id) REFERENCES public.onboarding_templates(id);


--
-- Name: verification_records fk_onboarding_sessions_verification_records; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.verification_records
    ADD CONSTRAINT fk_onboarding_sessions_verification_records FOREIGN KEY (onboarding_session_id) REFERENCES public.onboarding_sessions(id);


--
-- Name: task_execution_logs fk_onboarding_tasks_execution_logs; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.task_execution_logs
    ADD CONSTRAINT fk_onboarding_tasks_execution_logs FOREIGN KEY (onboarding_task_id) REFERENCES public.onboarding_tasks(id);


--
-- Name: tenant_auth_policies fk_tenant_auth_policies_tenant; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_auth_policies
    ADD CONSTRAINT fk_tenant_auth_policies_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: tenant_credentials fk_tenant_credentials_tenant; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tenant_credentials
    ADD CONSTRAINT fk_tenant_credentials_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: user_tenant_memberships fk_tenant_users_memberships; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_tenant_memberships
    ADD CONSTRAINT fk_tenant_users_memberships FOREIGN KEY (user_id) REFERENCES public.tenant_users(id);


--
-- Name: user_tenant_memberships fk_tenants_memberships; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_tenant_memberships
    ADD CONSTRAINT fk_tenants_memberships FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- PostgreSQL database dump complete
--

\unrestrict WZBWdbl3JSzWfrbhB1vmf6XspOxAD1zmtgjBBqzajtJVegfbiKC8uU4jmwz93PV

