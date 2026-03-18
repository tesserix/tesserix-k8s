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
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: document_access_level; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE IF NOT EXISTS public.document_access_level AS ENUM (
    'self_only',
    'manager',
    'hr_only',
    'admin_only'
);


--
-- Name: document_verification_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE IF NOT EXISTS public.document_verification_status AS ENUM (
    'pending',
    'under_review',
    'verified',
    'rejected',
    'expired',
    'requires_update'
);


--
-- Name: employment_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE IF NOT EXISTS public.employment_type AS ENUM (
    'full_time',
    'part_time',
    'contract',
    'temporary',
    'intern',
    'consultant',
    'volunteer'
);


--
-- Name: staff_account_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE IF NOT EXISTS public.staff_account_status AS ENUM (
    'pending_activation',
    'pending_password',
    'active',
    'suspended',
    'locked',
    'deactivated'
);


--
-- Name: staff_auth_method; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE IF NOT EXISTS public.staff_auth_method AS ENUM (
    'password',
    'google_sso',
    'microsoft_sso',
    'invitation_pending',
    'sso_pending',
    'okta_sso',
    'enterprise_sso'
);


--
-- Name: staff_document_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE IF NOT EXISTS public.staff_document_type AS ENUM (
    'id_proof_government_id',
    'id_proof_passport',
    'id_proof_drivers_license',
    'address_proof',
    'employment_contract',
    'offer_letter',
    'tax_w9',
    'tax_i9',
    'tax_w4',
    'tax_other',
    'background_check',
    'professional_certification',
    'education_certificate',
    'emergency_contact_form',
    'nda_agreement',
    'non_compete_agreement',
    'bank_details',
    'health_insurance',
    'other'
);


--
-- Name: staff_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE IF NOT EXISTS public.staff_role AS ENUM (
    'super_admin',
    'admin',
    'manager',
    'senior_employee',
    'employee',
    'intern',
    'contractor',
    'guest',
    'readonly',
    'store_owner',
    'store_admin',
    'store_manager',
    'inventory_manager',
    'marketing_manager',
    'order_manager',
    'customer_support',
    'viewer'
);


--
-- Name: TYPE staff_role; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TYPE public.staff_role IS 'Staff role enum including legacy roles (super_admin, admin, etc.) and RBAC roles (store_owner, store_admin, etc.)';


--
-- Name: two_factor_method; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE IF NOT EXISTS public.two_factor_method AS ENUM (
    'none',
    'sms',
    'email',
    'authenticator_app',
    'hardware_token',
    'biometric'
);


--
-- Name: check_and_lock_staff_account(uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE OR REPLACE FUNCTION public.check_and_lock_staff_account(p_staff_id uuid, p_max_attempts integer DEFAULT 5, p_lockout_minutes integer DEFAULT 30) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_failed_count INTEGER;
    v_last_failed TIMESTAMP WITH TIME ZONE;
BEGIN
    -- Count recent failed attempts
    SELECT COUNT(*), MAX(attempted_at)
    INTO v_failed_count, v_last_failed
    FROM staff_login_audit
    WHERE staff_id = p_staff_id
      AND success = false
      AND attempted_at > NOW() - INTERVAL '1 hour';

    -- If exceeded max attempts, lock the account
    IF v_failed_count >= p_max_attempts THEN
        UPDATE staff
        SET account_status = 'locked',
            account_locked_until = NOW() + (p_lockout_minutes || ' minutes')::INTERVAL
        WHERE id = p_staff_id;
        RETURN true; -- Account was locked
    END IF;

    RETURN false; -- Account not locked
END;
$$;


--
-- Name: generate_employee_id(character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE OR REPLACE FUNCTION public.generate_employee_id(p_tenant_id character varying, p_vendor_id character varying, p_business_code character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_employee_id VARCHAR(20);
    v_code_length INTEGER;
BEGIN
    -- Validate tenant_id is provided
    IF p_tenant_id IS NULL OR TRIM(p_tenant_id) = '' THEN
        RAISE EXCEPTION 'tenant_id is required for employee ID generation';
    END IF;

    -- Validate business_code length (3-5 characters) if provided
    IF p_business_code IS NOT NULL AND TRIM(p_business_code) != '' THEN
        v_code_length := LENGTH(TRIM(p_business_code));
        IF v_code_length < 3 OR v_code_length > 5 THEN
            RAISE EXCEPTION 'business_code must be between 3 and 5 characters';
        END IF;
    END IF;

    -- Generate the employee ID
    v_employee_id := get_next_employee_id(
        TRIM(p_tenant_id),
        TRIM(p_vendor_id),
        UPPER(TRIM(p_business_code))
    );

    RETURN v_employee_id;
END;
$$;


--
-- Name: FUNCTION generate_employee_id(p_tenant_id character varying, p_vendor_id character varying, p_business_code character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.generate_employee_id(p_tenant_id character varying, p_vendor_id character varying, p_business_code character varying) IS 'Validates input and generates employee ID with proper business code';


--
-- Name: generate_slug(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE OR REPLACE FUNCTION public.generate_slug(p_name character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_slug VARCHAR(100);
BEGIN
    -- Convert to lowercase, replace spaces and special chars with hyphens
    v_slug := LOWER(TRIM(p_name));
    v_slug := REGEXP_REPLACE(v_slug, '[^a-z0-9]+', '-', 'g');
    v_slug := REGEXP_REPLACE(v_slug, '^-|-$', '', 'g'); -- Remove leading/trailing hyphens
    v_slug := SUBSTRING(v_slug FROM 1 FOR 100); -- Limit to 100 chars

    RETURN v_slug;
END;
$_$;


--
-- Name: FUNCTION generate_slug(p_name character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.generate_slug(p_name character varying) IS 'Generates URL-safe slug from a name string';


--
-- Name: get_next_employee_id(character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE OR REPLACE FUNCTION public.get_next_employee_id(p_tenant_id character varying, p_vendor_id character varying, p_business_code character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_sequence INTEGER;
    v_vendor_id VARCHAR(255);
    v_prefix VARCHAR(10);
BEGIN
    -- Normalize NULL vendor_id to empty string for constraint matching
    v_vendor_id := NULLIF(COALESCE(p_vendor_id, ''), '');
    v_prefix := COALESCE(NULLIF(p_business_code, ''), 'EMP');

    -- Atomically insert or update the sequence
    INSERT INTO employee_id_sequences (tenant_id, vendor_id, current_sequence, prefix)
    VALUES (p_tenant_id, v_vendor_id, 1, v_prefix)
    ON CONFLICT (tenant_id, COALESCE(vendor_id, ''))
    DO UPDATE SET
        current_sequence = employee_id_sequences.current_sequence + 1,
        prefix = COALESCE(NULLIF(p_business_code, ''), employee_id_sequences.prefix),
        updated_at = NOW()
    RETURNING current_sequence INTO v_sequence;

    -- Return formatted employee ID: PREFIX-0000001
    RETURN CONCAT(v_prefix, '-', LPAD(v_sequence::TEXT, 7, '0'));
END;
$$;


--
-- Name: FUNCTION get_next_employee_id(p_tenant_id character varying, p_vendor_id character varying, p_business_code character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_next_employee_id(p_tenant_id character varying, p_vendor_id character varying, p_business_code character varying) IS 'Atomically generates the next employee ID in format PREFIX-0000001';


--
-- Name: seed_default_roles_for_tenant(character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE OR REPLACE FUNCTION public.seed_default_roles_for_tenant(p_tenant_id character varying, p_vendor_id character varying DEFAULT NULL::character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_owner_role_id UUID;
    v_admin_role_id UUID;
    v_manager_role_id UUID;
    v_inventory_role_id UUID;
    v_order_role_id UUID;
    v_support_role_id UUID;
    v_marketing_role_id UUID;
    v_viewer_role_id UUID;
BEGIN
    -- Generate UUIDs for roles
    v_owner_role_id := uuid_generate_v4();
    v_admin_role_id := uuid_generate_v4();
    v_manager_role_id := uuid_generate_v4();
    v_inventory_role_id := uuid_generate_v4();
    v_order_role_id := uuid_generate_v4();
    v_support_role_id := uuid_generate_v4();
    v_marketing_role_id := uuid_generate_v4();
    v_viewer_role_id := uuid_generate_v4();

    -- Insert default roles
    INSERT INTO staff_roles (id, tenant_id, vendor_id, name, display_name, description, priority_level, color, icon, is_system, can_manage_staff, can_create_roles, can_delete_roles, max_assignable_priority)
    VALUES
        (v_owner_role_id, p_tenant_id, p_vendor_id, 'store_owner', 'Store Owner', 'Full access to all features and settings', 100, '#7C3AED', 'Crown', true, true, true, true, 100),
        (v_admin_role_id, p_tenant_id, p_vendor_id, 'store_admin', 'Store Admin', 'Administrative access to most features', 90, '#2563EB', 'Shield', true, true, true, true, 90),
        (v_manager_role_id, p_tenant_id, p_vendor_id, 'store_manager', 'Store Manager', 'Manages daily operations and staff', 70, '#059669', 'UserCheck', true, true, false, false, 60),
        (v_inventory_role_id, p_tenant_id, p_vendor_id, 'inventory_manager', 'Inventory Manager', 'Manages stock and warehouse operations', 60, '#D97706', 'Package', true, false, false, false, NULL),
        (v_order_role_id, p_tenant_id, p_vendor_id, 'order_manager', 'Order Manager', 'Manages orders and fulfillment', 60, '#DC2626', 'ShoppingCart', true, false, false, false, NULL),
        (v_support_role_id, p_tenant_id, p_vendor_id, 'customer_support', 'Customer Support', 'Handles customer inquiries and issues', 50, '#0891B2', 'Headphones', true, false, false, false, NULL),
        (v_marketing_role_id, p_tenant_id, p_vendor_id, 'marketing_manager', 'Marketing Manager', 'Manages promotions and campaigns', 60, '#C026D3', 'Megaphone', true, false, false, false, NULL),
        (v_viewer_role_id, p_tenant_id, p_vendor_id, 'viewer', 'Viewer', 'Read-only access to most areas', 10, '#6B7280', 'Eye', true, false, false, false, NULL)
    ON CONFLICT DO NOTHING;

    -- =========================================================================
    -- STORE OWNER: Grant ALL permissions (super owner has full access)
    -- =========================================================================
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_owner_role_id, id, 'system'
    FROM staff_permissions
    ON CONFLICT DO NOTHING;

    -- =========================================================================
    -- STORE ADMIN: All permissions except sensitive payment/financial config
    -- =========================================================================
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_admin_role_id, id, 'system'
    FROM staff_permissions
    WHERE name NOT IN ('settings:payments:manage', 'finance:payouts:manage', 'finance:reconciliation:manage')
    ON CONFLICT DO NOTHING;

    -- =========================================================================
    -- STORE MANAGER: Operations and basic staff management
    -- =========================================================================
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_manager_role_id, id, 'system'
    FROM staff_permissions
    WHERE name IN (
        -- Catalog
        'catalog:products:view', 'catalog:products:create', 'catalog:products:edit', 'catalog:products:publish',
        'catalog:categories:view', 'catalog:pricing:view',
        -- Orders
        'orders:view', 'orders:edit', 'orders:fulfill', 'orders:shipping:manage', 'orders:returns:manage',
        -- Customers
        'customers:view', 'customers:edit', 'customers:notes:manage',
        -- Inventory
        'inventory:stock:view', 'inventory:stock:adjust', 'inventory:transfers:view',
        -- Analytics
        'analytics:dashboard:view', 'analytics:reports:view', 'analytics:sales:view',
        -- Team (limited) - using correct permission names
        'team:staff:view', 'team:staff:edit', 'team:staff:create',
        'team:roles:view', 'team:roles:assign',
        'team:departments:view', 'team:teams:view',
        -- Marketing (view)
        'marketing:coupons:view', 'marketing:campaigns:view', 'marketing:reviews:view',
        -- Gift cards (view)
        'giftcards:view', 'giftcards:create', 'giftcards:redeem', 'giftcards:transactions:view'
    )
    ON CONFLICT DO NOTHING;

    -- =========================================================================
    -- INVENTORY MANAGER: Stock and warehouse operations
    -- =========================================================================
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_inventory_role_id, id, 'system'
    FROM staff_permissions
    WHERE name LIKE 'inventory:%'
       OR name IN ('catalog:products:view', 'catalog:products:edit', 'catalog:variants:manage',
                   'team:staff:view', 'team:roles:view', 'team:departments:view', 'team:teams:view')
    ON CONFLICT DO NOTHING;

    -- =========================================================================
    -- ORDER MANAGER: Order processing and fulfillment
    -- =========================================================================
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_order_role_id, id, 'system'
    FROM staff_permissions
    WHERE name LIKE 'orders:%'
       OR name IN ('customers:view', 'customers:addresses:view', 'inventory:stock:view',
                   'team:staff:view', 'team:roles:view', 'team:departments:view', 'team:teams:view',
                   'giftcards:view', 'giftcards:redeem')
    ON CONFLICT DO NOTHING;

    -- =========================================================================
    -- CUSTOMER SUPPORT: Customer inquiries and issues
    -- =========================================================================
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_support_role_id, id, 'system'
    FROM staff_permissions
    WHERE name IN (
        'orders:view', 'orders:edit', 'orders:returns:manage',
        'customers:view', 'customers:edit', 'customers:notes:manage', 'customers:addresses:view',
        'marketing:reviews:view', 'marketing:reviews:moderate',
        'marketing:coupons:view', 'marketing:campaigns:view',
        'giftcards:view', 'giftcards:redeem',
        'team:staff:view', 'team:roles:view', 'team:departments:view', 'team:teams:view'
    )
    ON CONFLICT DO NOTHING;

    -- =========================================================================
    -- MARKETING MANAGER: Promotions, campaigns, and customer engagement
    -- =========================================================================
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_marketing_role_id, id, 'system'
    FROM staff_permissions
    WHERE name LIKE 'marketing:%'
       OR name IN (
           'catalog:products:view', 'catalog:categories:view', 'catalog:pricing:view',
           'customers:view', 'customers:segments:manage',
           'analytics:dashboard:view', 'analytics:reports:view', 'analytics:products:view',
           'giftcards:view', 'giftcards:create', 'giftcards:edit', 'giftcards:redeem', 'giftcards:transactions:view',
           'team:staff:view', 'team:roles:view', 'team:departments:view', 'team:teams:view'
       )
    ON CONFLICT DO NOTHING;

    -- =========================================================================
    -- VIEWER: Read-only access
    -- =========================================================================
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_viewer_role_id, id, 'system'
    FROM staff_permissions
    WHERE (action = 'view' AND is_sensitive = false)
       OR name IN ('team:staff:view', 'team:roles:view', 'team:departments:view', 'team:teams:view',
                   'giftcards:view', 'marketing:coupons:view', 'marketing:campaigns:view')
    ON CONFLICT DO NOTHING;

END;
$$;


--
-- Name: FUNCTION seed_default_roles_for_tenant(p_tenant_id character varying, p_vendor_id character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.seed_default_roles_for_tenant(p_tenant_id character varying, p_vendor_id character varying) IS 'Seeds default role templates and ALL permissions for a new tenant. Store Owner gets full access to everything. Call with tenant_id and optionally vendor_id.';


--
-- Name: seed_vendor_roles_for_vendor(character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE OR REPLACE FUNCTION public.seed_vendor_roles_for_vendor(p_tenant_id character varying, p_vendor_id character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_vendor_owner_id UUID;
    v_vendor_admin_id UUID;
    v_vendor_manager_id UUID;
    v_vendor_staff_id UUID;
BEGIN
    -- Generate UUIDs for vendor roles
    v_vendor_owner_id := uuid_generate_v4();
    v_vendor_admin_id := uuid_generate_v4();
    v_vendor_manager_id := uuid_generate_v4();
    v_vendor_staff_id := uuid_generate_v4();

    -- Insert vendor-specific roles
    -- These roles are scoped to the specific vendor via vendor_id
    INSERT INTO staff_roles (id, tenant_id, vendor_id, name, display_name, description, priority_level, color, icon, is_system, can_manage_staff, can_create_roles, can_delete_roles, max_assignable_priority)
    VALUES
        (v_vendor_owner_id, p_tenant_id, p_vendor_id, 'vendor_owner', 'Vendor Owner', 'Full access to vendor operations', 80, '#8B5CF6', 'Store', true, true, false, false, 65),
        (v_vendor_admin_id, p_tenant_id, p_vendor_id, 'vendor_admin', 'Vendor Admin', 'Administrative access to vendor operations', 75, '#3B82F6', 'ShieldCheck', true, true, false, false, 60),
        (v_vendor_manager_id, p_tenant_id, p_vendor_id, 'vendor_manager', 'Vendor Manager', 'Manages daily vendor operations', 65, '#10B981', 'UserCheck', true, false, false, false, NULL),
        (v_vendor_staff_id, p_tenant_id, p_vendor_id, 'vendor_staff', 'Vendor Staff', 'Basic vendor operations access', 55, '#6B7280', 'User', true, false, false, false, NULL)
    ON CONFLICT DO NOTHING;

    -- Assign ALL vendor permissions to Vendor Owner
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_vendor_owner_id, id, 'system'
    FROM staff_permissions
    WHERE name LIKE 'vendor:%'
    ON CONFLICT DO NOTHING;

    -- Assign permissions to Vendor Admin (all vendor permissions except staff management)
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_vendor_admin_id, id, 'system'
    FROM staff_permissions
    WHERE name LIKE 'vendor:%'
      AND name NOT IN ('vendor:staff:manage')
    ON CONFLICT DO NOTHING;

    -- Assign permissions to Vendor Manager
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_vendor_manager_id, id, 'system'
    FROM staff_permissions
    WHERE name IN (
        'vendor:products:view', 'vendor:products:create', 'vendor:products:edit',
        'vendor:orders:view', 'vendor:orders:fulfill',
        'vendor:inventory:view', 'vendor:inventory:adjust',
        'vendor:analytics:view',
        'vendor:settings:view',
        'vendor:staff:view'
    )
    ON CONFLICT DO NOTHING;

    -- Assign permissions to Vendor Staff (limited)
    INSERT INTO staff_role_permissions (role_id, permission_id, granted_by)
    SELECT v_vendor_staff_id, id, 'system'
    FROM staff_permissions
    WHERE name IN (
        'vendor:products:view',
        'vendor:orders:view', 'vendor:orders:fulfill',
        'vendor:inventory:view'
    )
    ON CONFLICT DO NOTHING;

END;
$$;


--
-- Name: FUNCTION seed_vendor_roles_for_vendor(p_tenant_id character varying, p_vendor_id character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.seed_vendor_roles_for_vendor(p_tenant_id character varying, p_vendor_id character varying) IS 'Seeds vendor-specific role templates and permissions for a new vendor. Call with tenant_id and vendor_id when creating a marketplace vendor.';


--
-- Name: unlock_expired_staff_accounts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE OR REPLACE FUNCTION public.unlock_expired_staff_accounts() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE staff
    SET account_status = 'active',
        account_locked_until = NULL,
        failed_login_attempts = 0
    WHERE account_status = 'locked'
      AND account_locked_until IS NOT NULL
      AND account_locked_until < NOW();

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;


--
-- Name: update_password_change_timestamp(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE OR REPLACE FUNCTION public.update_password_change_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.password_hash IS DISTINCT FROM OLD.password_hash THEN
        NEW.last_password_change = NOW();
        NEW.must_reset_password = false;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE OR REPLACE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: departments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.departments (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    name character varying(255) NOT NULL,
    code character varying(50),
    description text,
    parent_department_id uuid,
    department_head_id uuid,
    budget numeric(15,2),
    cost_center character varying(100),
    location character varying(255),
    is_active boolean DEFAULT true,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    created_by character varying(255),
    updated_by character varying(255),
    slug character varying(100)
);


--
-- Name: TABLE departments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.departments IS 'Organizational departments with hierarchical structure';


--
-- Name: COLUMN departments.slug; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.departments.slug IS 'URL-safe auto-generated code from department name';


--
-- Name: employee_id_sequences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.employee_id_sequences (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    current_sequence integer DEFAULT 0 NOT NULL,
    prefix character varying(10),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE employee_id_sequences; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.employee_id_sequences IS 'Tracks auto-increment sequences for employee IDs per tenant/vendor';


--
-- Name: COLUMN employee_id_sequences.current_sequence; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.employee_id_sequences.current_sequence IS 'Current sequence number (last used)';


--
-- Name: COLUMN employee_id_sequences.prefix; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.employee_id_sequences.prefix IS 'Business code prefix (3-5 chars) for employee IDs';


--
-- Name: permission_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.permission_categories (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying(100) NOT NULL,
    display_name character varying(255) NOT NULL,
    description text,
    icon character varying(50),
    sort_order integer DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE permission_categories; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.permission_categories IS 'Categories for grouping related permissions';


--
-- Name: scim_sync_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.scim_sync_log (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    operation character varying(50) NOT NULL,
    resource_type character varying(50) NOT NULL,
    resource_id character varying(255),
    external_id character varying(255),
    success boolean NOT NULL,
    error_message text,
    user_email character varying(255),
    user_display_name character varying(255),
    request_id character varying(255),
    source_ip character varying(50),
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE scim_sync_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.scim_sync_log IS 'Audit log for SCIM user provisioning operations';


--
-- Name: staff; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    application_id character varying(255),
    vendor_id character varying(255),
    first_name character varying(255) NOT NULL,
    last_name character varying(255) NOT NULL,
    middle_name character varying(255),
    display_name character varying(255),
    email character varying(255) NOT NULL,
    alternate_email character varying(255),
    phone_number character varying(50),
    mobile_number character varying(50),
    employee_id character varying(100),
    role public.staff_role NOT NULL,
    employment_type public.employment_type NOT NULL,
    start_date timestamp with time zone,
    end_date timestamp with time zone,
    probation_end_date timestamp with time zone,
    department_id character varying(255),
    team_id character varying(255),
    manager_id uuid,
    location_id character varying(255),
    cost_center character varying(255),
    profile_photo_url text,
    timezone character varying(100),
    locale character varying(10),
    skills jsonb,
    certifications jsonb,
    is_active boolean DEFAULT true NOT NULL,
    is_verified boolean DEFAULT false,
    last_login_at timestamp with time zone,
    last_activity_at timestamp with time zone,
    failed_login_attempts integer DEFAULT 0,
    account_locked_until timestamp with time zone,
    password_last_changed_at timestamp with time zone,
    password_expires_at timestamp with time zone,
    two_factor_enabled boolean DEFAULT false,
    two_factor_method public.two_factor_method DEFAULT 'none'::public.two_factor_method,
    allowed_ip_ranges jsonb,
    trusted_devices jsonb,
    custom_fields jsonb,
    tags jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    created_by character varying(255),
    updated_by character varying(255),
    department_uuid uuid,
    team_uuid uuid,
    auth_method public.staff_auth_method DEFAULT 'invitation_pending'::public.staff_auth_method,
    account_status public.staff_account_status DEFAULT 'pending_activation'::public.staff_account_status,
    password_hash character varying(255),
    must_reset_password boolean DEFAULT false,
    password_reset_token character varying(255),
    password_reset_token_expires_at timestamp with time zone,
    activation_token character varying(255),
    activation_token_expires_at timestamp with time zone,
    is_email_verified boolean DEFAULT false,
    invited_at timestamp with time zone,
    invitation_accepted_at timestamp with time zone,
    invited_by uuid,
    google_id character varying(255),
    microsoft_id character varying(255),
    sso_profile_data jsonb,
    last_password_change timestamp with time zone,
    password_history jsonb,
    login_history jsonb,
    profile_photo_document_id uuid,
    job_title character varying(255),
    street_address character varying(500),
    street_address_2 character varying(500),
    city character varying(255),
    state character varying(255),
    state_code character varying(10),
    postal_code character varying(20),
    country character varying(255),
    country_code character varying(3),
    latitude numeric(10,8),
    longitude numeric(11,8),
    formatted_address text,
    place_id character varying(255),
    okta_id character varying(255),
    keycloak_user_id character varying(255)
);


--
-- Name: COLUMN staff.auth_method; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.auth_method IS 'Primary authentication method for staff member';


--
-- Name: COLUMN staff.account_status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.account_status IS 'Current account activation/lock status';


--
-- Name: COLUMN staff.must_reset_password; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.must_reset_password IS 'If true, staff must reset password on next login';


--
-- Name: COLUMN staff.profile_photo_document_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.profile_photo_document_id IS 'Reference to profile photo in document-service';


--
-- Name: COLUMN staff.street_address; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.street_address IS 'Primary street address';


--
-- Name: COLUMN staff.street_address_2; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.street_address_2 IS 'Secondary address line (apt, suite, etc.)';


--
-- Name: COLUMN staff.city; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.city IS 'City name';


--
-- Name: COLUMN staff.state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.state IS 'State/Province full name';


--
-- Name: COLUMN staff.state_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.state_code IS 'State/Province code (e.g., NSW, CA)';


--
-- Name: COLUMN staff.postal_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.postal_code IS 'Postal/ZIP code';


--
-- Name: COLUMN staff.country; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.country IS 'Country full name';


--
-- Name: COLUMN staff.country_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.country_code IS 'ISO 3166-1 alpha-2 country code (e.g., AU, US)';


--
-- Name: COLUMN staff.latitude; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.latitude IS 'GPS latitude coordinate';


--
-- Name: COLUMN staff.longitude; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.longitude IS 'GPS longitude coordinate';


--
-- Name: COLUMN staff.formatted_address; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.formatted_address IS 'Full formatted address string';


--
-- Name: COLUMN staff.place_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff.place_id IS 'Google Places ID for the address';


--
-- Name: staff_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_documents (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    staff_id uuid NOT NULL,
    document_type public.staff_document_type NOT NULL,
    document_name character varying(255) NOT NULL,
    original_filename character varying(500),
    document_number character varying(255),
    issuing_authority character varying(255),
    issue_date date,
    expiry_date date,
    storage_path text NOT NULL,
    file_size bigint,
    mime_type character varying(100),
    verification_status public.document_verification_status DEFAULT 'pending'::public.document_verification_status NOT NULL,
    verified_at timestamp with time zone,
    verified_by uuid,
    verification_notes text,
    rejection_reason text,
    access_level public.document_access_level DEFAULT 'hr_only'::public.document_access_level NOT NULL,
    is_mandatory boolean DEFAULT false,
    reminder_sent_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    created_by character varying(255),
    updated_by character varying(255)
);


--
-- Name: TABLE staff_documents; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_documents IS 'Staff verification documents with approval workflow';


--
-- Name: COLUMN staff_documents.access_level; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff_documents.access_level IS 'Who can view this document: self_only, manager, hr_only, admin_only';


--
-- Name: staff_emergency_contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_emergency_contacts (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    staff_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    relationship character varying(100),
    phone_primary character varying(50) NOT NULL,
    phone_secondary character varying(50),
    email character varying(255),
    address text,
    is_primary boolean DEFAULT false,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE staff_emergency_contacts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_emergency_contacts IS 'Emergency contact information for staff';


--
-- Name: staff_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_invitations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    staff_id uuid NOT NULL,
    invitation_token character varying(255) NOT NULL,
    invitation_type character varying(50) NOT NULL,
    auth_method_options jsonb,
    sent_to_email character varying(255),
    sent_to_phone character varying(50),
    status character varying(50) DEFAULT 'pending'::character varying,
    sent_at timestamp with time zone,
    opened_at timestamp with time zone,
    accepted_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    sent_by uuid,
    send_count integer DEFAULT 0,
    last_sent_at timestamp with time zone,
    custom_message text,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE staff_invitations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_invitations IS 'Staff invitations tracking';


--
-- Name: staff_login_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_login_audit (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    staff_id uuid,
    email character varying(255),
    auth_method character varying(50),
    success boolean NOT NULL,
    failure_reason character varying(255),
    ip_address character varying(50),
    user_agent text,
    device_fingerprint character varying(255),
    location character varying(255),
    risk_score integer,
    risk_factors jsonb,
    attempted_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE staff_login_audit; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_login_audit IS 'Audit log of all login attempts';


--
-- Name: staff_oauth_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_oauth_providers (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    staff_id uuid NOT NULL,
    provider character varying(50) NOT NULL,
    provider_user_id character varying(255) NOT NULL,
    provider_email character varying(255),
    provider_name character varying(255),
    provider_avatar_url text,
    access_token text,
    refresh_token text,
    token_expires_at timestamp with time zone,
    profile_data jsonb,
    is_primary boolean DEFAULT false,
    last_used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE staff_oauth_providers; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_oauth_providers IS 'Linked OAuth/SSO providers for staff accounts';


--
-- Name: staff_password_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_password_history (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    staff_id uuid NOT NULL,
    password_hash character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: TABLE staff_password_history; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_password_history IS 'Password history to prevent reuse';


--
-- Name: staff_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_permissions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    category_id uuid,
    name character varying(150) NOT NULL,
    display_name character varying(255) NOT NULL,
    description text,
    resource character varying(100),
    action character varying(100),
    is_sensitive boolean DEFAULT false,
    requires_2fa boolean DEFAULT false,
    is_active boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE staff_permissions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_permissions IS 'Global permission definitions available across all tenants';


--
-- Name: staff_rbac_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_rbac_audit_log (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    action character varying(100) NOT NULL,
    entity_type character varying(50) NOT NULL,
    entity_id uuid NOT NULL,
    target_staff_id uuid,
    performed_by uuid,
    old_value jsonb,
    new_value jsonb,
    ip_address inet,
    user_agent text,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE staff_rbac_audit_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_rbac_audit_log IS 'Audit trail for all RBAC-related changes';


--
-- Name: staff_role_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_role_assignments (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    staff_id uuid NOT NULL,
    role_id uuid NOT NULL,
    is_primary boolean DEFAULT false,
    scope character varying(100),
    scope_id uuid,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL,
    assigned_by uuid,
    expires_at timestamp with time zone,
    notes text,
    is_active boolean DEFAULT true
);


--
-- Name: TABLE staff_role_assignments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_role_assignments IS 'Assignments of roles to staff members';


--
-- Name: COLUMN staff_role_assignments.scope; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff_role_assignments.scope IS 'Scope of the role: global, department:uuid, team:uuid';


--
-- Name: staff_role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_role_permissions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    role_id uuid NOT NULL,
    permission_id uuid NOT NULL,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    granted_by character varying(255)
);


--
-- Name: TABLE staff_role_permissions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_role_permissions IS 'Junction table linking roles to their permissions';


--
-- Name: staff_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_roles (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    name character varying(100) NOT NULL,
    display_name character varying(255) NOT NULL,
    description text,
    priority_level integer DEFAULT 0,
    color character varying(20) DEFAULT '#6B7280'::character varying,
    icon character varying(50) DEFAULT 'UserCircle'::character varying,
    is_system boolean DEFAULT false,
    is_template boolean DEFAULT false,
    template_source character varying(100),
    can_manage_staff boolean DEFAULT false,
    can_create_roles boolean DEFAULT false,
    can_delete_roles boolean DEFAULT false,
    max_assignable_priority integer,
    is_active boolean DEFAULT true,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    created_by character varying(255),
    updated_by character varying(255)
);


--
-- Name: TABLE staff_roles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_roles IS 'Tenant-specific roles with customizable permissions';


--
-- Name: COLUMN staff_roles.priority_level; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff_roles.priority_level IS 'Higher values = more authority. Owner=100, Viewer=10. Staff can only assign roles with priority <= their own max priority.';


--
-- Name: COLUMN staff_roles.is_system; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.staff_roles.is_system IS 'System roles cannot be deleted or have their core permissions modified';


--
-- Name: staff_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.staff_sessions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    staff_id uuid NOT NULL,
    access_token text NOT NULL,
    refresh_token text,
    access_token_expires_at timestamp with time zone NOT NULL,
    refresh_token_expires_at timestamp with time zone,
    device_fingerprint character varying(255),
    device_name character varying(255),
    device_type character varying(50),
    os_name character varying(100),
    os_version character varying(50),
    browser_name character varying(100),
    browser_version character varying(50),
    ip_address character varying(50),
    location character varying(255),
    user_agent text,
    is_active boolean DEFAULT true,
    is_trusted boolean DEFAULT false,
    last_activity_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    revoked_at timestamp with time zone,
    revoked_reason character varying(255)
);


--
-- Name: TABLE staff_sessions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.staff_sessions IS 'Active authentication sessions for staff members';


--
-- Name: teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.teams (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    department_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    code character varying(50),
    description text,
    team_lead_id uuid,
    max_capacity integer,
    slack_channel character varying(255),
    email_alias character varying(255),
    is_active boolean DEFAULT true,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    created_by character varying(255),
    updated_by character varying(255),
    slug character varying(100),
    default_role_id uuid
);


--
-- Name: TABLE teams; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.teams IS 'Teams within departments for granular staff organization';


--
-- Name: COLUMN teams.slug; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.teams.slug IS 'URL-safe auto-generated code from team name';


--
-- Name: COLUMN teams.default_role_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.teams.default_role_id IS 'Default role assigned to team members - permissions from this role are inherited by all team members';


--
-- Name: tenant_secrets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_secrets (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    secret_name character varying(255) NOT NULL,
    secret_type character varying(50) NOT NULL,
    provider character varying(50),
    gcp_secret_id character varying(500) NOT NULL,
    gcp_secret_version character varying(50) DEFAULT 'latest'::character varying,
    description text,
    is_active boolean DEFAULT true,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(255),
    last_rotated_at timestamp with time zone,
    rotation_count integer DEFAULT 0
);


--
-- Name: TABLE tenant_secrets; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tenant_secrets IS 'Registry of GCP Secret Manager secrets per tenant for SSO/SCIM integrations';


--
-- Name: tenant_sso_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_sso_config (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    google_enabled boolean DEFAULT false,
    google_client_id character varying(255),
    google_client_secret character varying(500),
    google_allowed_domains jsonb,
    microsoft_enabled boolean DEFAULT false,
    microsoft_tenant_id character varying(255),
    microsoft_client_id character varying(255),
    microsoft_client_secret character varying(500),
    microsoft_allowed_groups jsonb,
    allow_password_auth boolean DEFAULT true,
    enforce_sso boolean DEFAULT false,
    auto_provision_users boolean DEFAULT false,
    default_role_id uuid,
    session_duration_hours integer DEFAULT 8,
    refresh_token_days integer DEFAULT 30,
    max_sessions_per_user integer DEFAULT 5,
    require_mfa boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    created_by character varying(255),
    updated_by character varying(255),
    okta_enabled boolean DEFAULT false,
    okta_domain character varying(255),
    okta_client_id character varying(255),
    okta_client_secret_ref character varying(500),
    okta_protocol character varying(20) DEFAULT 'oidc'::character varying,
    okta_saml_metadata_url text,
    okta_saml_entity_id character varying(500),
    okta_saml_certificate_ref character varying(500),
    okta_allowed_groups jsonb,
    scim_enabled boolean DEFAULT false,
    scim_endpoint character varying(500),
    scim_bearer_token_ref character varying(500),
    scim_sync_interval_minutes integer DEFAULT 60,
    scim_last_sync_at timestamp with time zone,
    scim_auto_create_users boolean DEFAULT true,
    scim_auto_deactivate_users boolean DEFAULT true,
    scim_token_created_at timestamp with time zone,
    scim_token_last_used_at timestamp with time zone,
    google_client_secret_ref character varying(500),
    microsoft_client_secret_ref character varying(500),
    keycloak_microsoft_idp_alias character varying(255),
    keycloak_okta_idp_alias character varying(255),
    keycloak_google_idp_alias character varying(255),
    keycloak_federation_enabled boolean DEFAULT false,
    keycloak_last_sync_at timestamp with time zone
);


--
-- Name: TABLE tenant_sso_config; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tenant_sso_config IS 'SSO configuration per tenant';


--
-- Name: COLUMN tenant_sso_config.okta_enabled; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.okta_enabled IS 'Whether Okta SSO is enabled for this tenant';


--
-- Name: COLUMN tenant_sso_config.okta_domain; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.okta_domain IS 'Okta organization domain (e.g., company.okta.com)';


--
-- Name: COLUMN tenant_sso_config.okta_client_secret_ref; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.okta_client_secret_ref IS 'GCP Secret Manager reference for Okta client secret';


--
-- Name: COLUMN tenant_sso_config.okta_protocol; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.okta_protocol IS 'Authentication protocol: oidc or saml';


--
-- Name: COLUMN tenant_sso_config.okta_saml_certificate_ref; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.okta_saml_certificate_ref IS 'GCP Secret Manager reference for Okta SAML certificate';


--
-- Name: COLUMN tenant_sso_config.scim_enabled; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.scim_enabled IS 'Whether SCIM 2.0 user provisioning is enabled';


--
-- Name: COLUMN tenant_sso_config.scim_bearer_token_ref; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.scim_bearer_token_ref IS 'GCP Secret Manager reference for SCIM bearer token';


--
-- Name: COLUMN tenant_sso_config.google_client_secret_ref; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.google_client_secret_ref IS 'GCP Secret Manager reference for Google OAuth client secret';


--
-- Name: COLUMN tenant_sso_config.microsoft_client_secret_ref; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.microsoft_client_secret_ref IS 'GCP Secret Manager reference for Microsoft Entra client secret';


--
-- Name: COLUMN tenant_sso_config.keycloak_microsoft_idp_alias; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.keycloak_microsoft_idp_alias IS 'KeyCloak IdP alias for Microsoft Entra federation';


--
-- Name: COLUMN tenant_sso_config.keycloak_okta_idp_alias; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tenant_sso_config.keycloak_okta_idp_alias IS 'KeyCloak IdP alias for Okta federation';


--
-- Name: departments departments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_pkey PRIMARY KEY (id);


--
-- Name: employee_id_sequences employee_id_sequences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_id_sequences
    ADD CONSTRAINT employee_id_sequences_pkey PRIMARY KEY (id);


--
-- Name: permission_categories permission_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permission_categories
    ADD CONSTRAINT permission_categories_name_key UNIQUE (name);


--
-- Name: permission_categories permission_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permission_categories
    ADD CONSTRAINT permission_categories_pkey PRIMARY KEY (id);


--
-- Name: scim_sync_log scim_sync_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scim_sync_log
    ADD CONSTRAINT scim_sync_log_pkey PRIMARY KEY (id);


--
-- Name: staff_documents staff_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_documents
    ADD CONSTRAINT staff_documents_pkey PRIMARY KEY (id);


--
-- Name: staff_emergency_contacts staff_emergency_contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_emergency_contacts
    ADD CONSTRAINT staff_emergency_contacts_pkey PRIMARY KEY (id);


--
-- Name: staff_invitations staff_invitations_invitation_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_invitations
    ADD CONSTRAINT staff_invitations_invitation_token_key UNIQUE (invitation_token);


--
-- Name: staff_invitations staff_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_invitations
    ADD CONSTRAINT staff_invitations_pkey PRIMARY KEY (id);


--
-- Name: staff_login_audit staff_login_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_login_audit
    ADD CONSTRAINT staff_login_audit_pkey PRIMARY KEY (id);


--
-- Name: staff_oauth_providers staff_oauth_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_oauth_providers
    ADD CONSTRAINT staff_oauth_providers_pkey PRIMARY KEY (id);


--
-- Name: staff_oauth_providers staff_oauth_providers_tenant_id_provider_provider_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_oauth_providers
    ADD CONSTRAINT staff_oauth_providers_tenant_id_provider_provider_user_id_key UNIQUE (tenant_id, provider, provider_user_id);


--
-- Name: staff_password_history staff_password_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_password_history
    ADD CONSTRAINT staff_password_history_pkey PRIMARY KEY (id);


--
-- Name: staff_permissions staff_permissions_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_permissions
    ADD CONSTRAINT staff_permissions_name_key UNIQUE (name);


--
-- Name: staff_permissions staff_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_permissions
    ADD CONSTRAINT staff_permissions_pkey PRIMARY KEY (id);


--
-- Name: staff staff_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_pkey PRIMARY KEY (id);


--
-- Name: staff_rbac_audit_log staff_rbac_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_rbac_audit_log
    ADD CONSTRAINT staff_rbac_audit_log_pkey PRIMARY KEY (id);


--
-- Name: staff_role_assignments staff_role_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_role_assignments
    ADD CONSTRAINT staff_role_assignments_pkey PRIMARY KEY (id);


--
-- Name: staff_role_permissions staff_role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_role_permissions
    ADD CONSTRAINT staff_role_permissions_pkey PRIMARY KEY (id);


--
-- Name: staff_role_permissions staff_role_permissions_role_id_permission_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_role_permissions
    ADD CONSTRAINT staff_role_permissions_role_id_permission_id_key UNIQUE (role_id, permission_id);


--
-- Name: staff_roles staff_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_roles
    ADD CONSTRAINT staff_roles_pkey PRIMARY KEY (id);


--
-- Name: staff_sessions staff_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_sessions
    ADD CONSTRAINT staff_sessions_pkey PRIMARY KEY (id);


--
-- Name: teams teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_pkey PRIMARY KEY (id);


--
-- Name: tenant_secrets tenant_secrets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_secrets
    ADD CONSTRAINT tenant_secrets_pkey PRIMARY KEY (id);


--
-- Name: tenant_secrets tenant_secrets_tenant_id_secret_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_secrets
    ADD CONSTRAINT tenant_secrets_tenant_id_secret_name_key UNIQUE (tenant_id, secret_name);


--
-- Name: tenant_sso_config tenant_sso_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_sso_config
    ADD CONSTRAINT tenant_sso_config_pkey PRIMARY KEY (id);


--
-- Name: tenant_sso_config tenant_sso_config_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_sso_config
    ADD CONSTRAINT tenant_sso_config_tenant_id_key UNIQUE (tenant_id);


--
-- Name: idx_departments_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_departments_deleted_at ON public.departments USING btree (deleted_at);


--
-- Name: idx_departments_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_departments_is_active ON public.departments USING btree (is_active);


--
-- Name: idx_departments_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_departments_parent_id ON public.departments USING btree (parent_department_id);


--
-- Name: idx_departments_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_departments_slug ON public.departments USING btree (tenant_id, slug) WHERE (deleted_at IS NULL);


--
-- Name: idx_departments_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_departments_tenant_id ON public.departments USING btree (tenant_id);


--
-- Name: idx_departments_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_departments_tenant_vendor ON public.departments USING btree (tenant_id, vendor_id);


--
-- Name: idx_departments_tenant_vendor_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_departments_tenant_vendor_code ON public.departments USING btree (tenant_id, COALESCE(vendor_id, ''::character varying), code) WHERE ((deleted_at IS NULL) AND (code IS NOT NULL));


--
-- Name: idx_departments_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_departments_vendor_id ON public.departments USING btree (vendor_id);


--
-- Name: idx_employee_id_sequences_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_employee_id_sequences_tenant ON public.employee_id_sequences USING btree (tenant_id);


--
-- Name: idx_employee_id_sequences_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_employee_id_sequences_tenant_vendor ON public.employee_id_sequences USING btree (tenant_id, COALESCE(vendor_id, ''::character varying));


--
-- Name: idx_scim_sync_log_failures; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_scim_sync_log_failures ON public.scim_sync_log USING btree (tenant_id, success) WHERE (success = false);


--
-- Name: idx_scim_sync_log_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_scim_sync_log_resource ON public.scim_sync_log USING btree (tenant_id, resource_type, resource_id);


--
-- Name: idx_scim_sync_log_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_scim_sync_log_tenant ON public.scim_sync_log USING btree (tenant_id);


--
-- Name: idx_scim_sync_log_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_scim_sync_log_time ON public.scim_sync_log USING btree (created_at DESC);


--
-- Name: idx_staff_account_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_account_status ON public.staff USING btree (account_status);


--
-- Name: idx_staff_activation_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_activation_token ON public.staff USING btree (activation_token) WHERE (activation_token IS NOT NULL);


--
-- Name: idx_staff_auth_method; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_auth_method ON public.staff USING btree (auth_method);


--
-- Name: idx_staff_certifications_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_certifications_gin ON public.staff USING gin (certifications);


--
-- Name: idx_staff_city; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_city ON public.staff USING btree (city);


--
-- Name: idx_staff_country_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_country_code ON public.staff USING btree (country_code);


--
-- Name: idx_staff_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_created_at ON public.staff USING btree (created_at);


--
-- Name: idx_staff_custom_fields_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_custom_fields_gin ON public.staff USING gin (custom_fields);


--
-- Name: idx_staff_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_deleted_at ON public.staff USING btree (deleted_at);


--
-- Name: idx_staff_department_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_department_id ON public.staff USING btree (department_id);


--
-- Name: idx_staff_department_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_department_uuid ON public.staff USING btree (department_uuid);


--
-- Name: idx_staff_documents_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_documents_deleted_at ON public.staff_documents USING btree (deleted_at);


--
-- Name: idx_staff_documents_document_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_documents_document_type ON public.staff_documents USING btree (document_type);


--
-- Name: idx_staff_documents_expiry_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_documents_expiry_date ON public.staff_documents USING btree (expiry_date);


--
-- Name: idx_staff_documents_staff_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_documents_staff_id ON public.staff_documents USING btree (staff_id);


--
-- Name: idx_staff_documents_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_documents_tenant_id ON public.staff_documents USING btree (tenant_id);


--
-- Name: idx_staff_documents_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_documents_tenant_vendor ON public.staff_documents USING btree (tenant_id, vendor_id);


--
-- Name: idx_staff_documents_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_documents_vendor_id ON public.staff_documents USING btree (vendor_id);


--
-- Name: idx_staff_documents_verification_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_documents_verification_status ON public.staff_documents USING btree (verification_status);


--
-- Name: idx_staff_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_email ON public.staff USING btree (email);


--
-- Name: idx_staff_emergency_contacts_is_primary; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_emergency_contacts_is_primary ON public.staff_emergency_contacts USING btree (is_primary);


--
-- Name: idx_staff_emergency_contacts_staff_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_emergency_contacts_staff_id ON public.staff_emergency_contacts USING btree (staff_id);


--
-- Name: idx_staff_emergency_contacts_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_emergency_contacts_tenant_id ON public.staff_emergency_contacts USING btree (tenant_id);


--
-- Name: idx_staff_emergency_contacts_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_emergency_contacts_vendor_id ON public.staff_emergency_contacts USING btree (vendor_id);


--
-- Name: idx_staff_employee_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_employee_id ON public.staff USING btree (employee_id);


--
-- Name: idx_staff_employment_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_employment_type ON public.staff USING btree (employment_type);


--
-- Name: idx_staff_google_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_google_id ON public.staff USING btree (google_id) WHERE (google_id IS NOT NULL);


--
-- Name: idx_staff_invitations_staff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_invitations_staff ON public.staff_invitations USING btree (staff_id);


--
-- Name: idx_staff_invitations_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_invitations_status ON public.staff_invitations USING btree (status, expires_at);


--
-- Name: idx_staff_invitations_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_invitations_tenant ON public.staff_invitations USING btree (tenant_id);


--
-- Name: idx_staff_invitations_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_invitations_token ON public.staff_invitations USING btree (invitation_token);


--
-- Name: idx_staff_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_is_active ON public.staff USING btree (is_active);


--
-- Name: idx_staff_keycloak_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_keycloak_id ON public.staff USING btree (keycloak_user_id) WHERE (keycloak_user_id IS NOT NULL);


--
-- Name: idx_staff_login_audit_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_login_audit_email ON public.staff_login_audit USING btree (email);


--
-- Name: idx_staff_login_audit_failed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_login_audit_failed ON public.staff_login_audit USING btree (staff_id, success, attempted_at) WHERE (success = false);


--
-- Name: idx_staff_login_audit_staff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_login_audit_staff ON public.staff_login_audit USING btree (staff_id);


--
-- Name: idx_staff_login_audit_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_login_audit_tenant ON public.staff_login_audit USING btree (tenant_id);


--
-- Name: idx_staff_login_audit_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_login_audit_time ON public.staff_login_audit USING btree (attempted_at DESC);


--
-- Name: idx_staff_manager_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_manager_id ON public.staff USING btree (manager_id);


--
-- Name: idx_staff_microsoft_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_microsoft_id ON public.staff USING btree (microsoft_id) WHERE (microsoft_id IS NOT NULL);


--
-- Name: idx_staff_oauth_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_oauth_provider ON public.staff_oauth_providers USING btree (provider, provider_user_id);


--
-- Name: idx_staff_oauth_staff_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_oauth_staff_id ON public.staff_oauth_providers USING btree (staff_id);


--
-- Name: idx_staff_oauth_tenant_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_oauth_tenant_provider ON public.staff_oauth_providers USING btree (tenant_id, provider);


--
-- Name: idx_staff_okta_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_okta_id ON public.staff USING btree (okta_id) WHERE (okta_id IS NOT NULL);


--
-- Name: idx_staff_password_history_staff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_password_history_staff ON public.staff_password_history USING btree (staff_id);


--
-- Name: idx_staff_password_reset_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_password_reset_token ON public.staff USING btree (password_reset_token) WHERE (password_reset_token IS NOT NULL);


--
-- Name: idx_staff_permissions_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_permissions_category_id ON public.staff_permissions USING btree (category_id);


--
-- Name: idx_staff_permissions_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_permissions_is_active ON public.staff_permissions USING btree (is_active);


--
-- Name: idx_staff_permissions_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_permissions_resource ON public.staff_permissions USING btree (resource);


--
-- Name: idx_staff_rbac_audit_log_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_rbac_audit_log_action ON public.staff_rbac_audit_log USING btree (action);


--
-- Name: idx_staff_rbac_audit_log_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_rbac_audit_log_created_at ON public.staff_rbac_audit_log USING btree (created_at);


--
-- Name: idx_staff_rbac_audit_log_entity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_rbac_audit_log_entity ON public.staff_rbac_audit_log USING btree (entity_type, entity_id);


--
-- Name: idx_staff_rbac_audit_log_performed_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_rbac_audit_log_performed_by ON public.staff_rbac_audit_log USING btree (performed_by);


--
-- Name: idx_staff_rbac_audit_log_target_staff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_rbac_audit_log_target_staff ON public.staff_rbac_audit_log USING btree (target_staff_id);


--
-- Name: idx_staff_rbac_audit_log_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_rbac_audit_log_tenant_id ON public.staff_rbac_audit_log USING btree (tenant_id);


--
-- Name: idx_staff_rbac_audit_log_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_rbac_audit_log_tenant_vendor ON public.staff_rbac_audit_log USING btree (tenant_id, vendor_id);


--
-- Name: idx_staff_rbac_audit_log_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_rbac_audit_log_vendor_id ON public.staff_rbac_audit_log USING btree (vendor_id);


--
-- Name: idx_staff_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role ON public.staff USING btree (role);


--
-- Name: idx_staff_role_assignments_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_assignments_expires_at ON public.staff_role_assignments USING btree (expires_at);


--
-- Name: idx_staff_role_assignments_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_assignments_is_active ON public.staff_role_assignments USING btree (is_active);


--
-- Name: idx_staff_role_assignments_is_primary; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_assignments_is_primary ON public.staff_role_assignments USING btree (is_primary);


--
-- Name: idx_staff_role_assignments_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_assignments_role_id ON public.staff_role_assignments USING btree (role_id);


--
-- Name: idx_staff_role_assignments_staff_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_assignments_staff_id ON public.staff_role_assignments USING btree (staff_id);


--
-- Name: idx_staff_role_assignments_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_assignments_tenant_id ON public.staff_role_assignments USING btree (tenant_id);


--
-- Name: idx_staff_role_assignments_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_assignments_tenant_vendor ON public.staff_role_assignments USING btree (tenant_id, vendor_id);


--
-- Name: idx_staff_role_assignments_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_role_assignments_unique ON public.staff_role_assignments USING btree (staff_id, role_id, COALESCE(vendor_id, ''::character varying), COALESCE(scope, ''::character varying), COALESCE(scope_id, '00000000-0000-0000-0000-000000000000'::uuid));


--
-- Name: idx_staff_role_assignments_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_assignments_vendor_id ON public.staff_role_assignments USING btree (vendor_id);


--
-- Name: idx_staff_role_permissions_permission_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_permissions_permission_id ON public.staff_role_permissions USING btree (permission_id);


--
-- Name: idx_staff_role_permissions_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_role_permissions_role_id ON public.staff_role_permissions USING btree (role_id);


--
-- Name: idx_staff_roles_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_roles_deleted_at ON public.staff_roles USING btree (deleted_at);


--
-- Name: idx_staff_roles_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_roles_is_active ON public.staff_roles USING btree (is_active);


--
-- Name: idx_staff_roles_is_system; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_roles_is_system ON public.staff_roles USING btree (is_system);


--
-- Name: idx_staff_roles_priority_level; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_roles_priority_level ON public.staff_roles USING btree (priority_level);


--
-- Name: idx_staff_roles_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_roles_tenant_id ON public.staff_roles USING btree (tenant_id);


--
-- Name: idx_staff_roles_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_roles_tenant_vendor ON public.staff_roles USING btree (tenant_id, vendor_id);


--
-- Name: idx_staff_roles_tenant_vendor_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_roles_tenant_vendor_name ON public.staff_roles USING btree (tenant_id, COALESCE(vendor_id, ''::character varying), name) WHERE (deleted_at IS NULL);


--
-- Name: idx_staff_roles_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_roles_vendor_id ON public.staff_roles USING btree (vendor_id);


--
-- Name: idx_staff_sessions_access_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_sessions_access_token ON public.staff_sessions USING btree (access_token);


--
-- Name: idx_staff_sessions_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_sessions_active ON public.staff_sessions USING btree (staff_id, is_active) WHERE (is_active = true);


--
-- Name: idx_staff_sessions_refresh_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_sessions_refresh_token ON public.staff_sessions USING btree (refresh_token) WHERE (refresh_token IS NOT NULL);


--
-- Name: idx_staff_sessions_staff_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_sessions_staff_id ON public.staff_sessions USING btree (staff_id);


--
-- Name: idx_staff_sessions_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_sessions_tenant ON public.staff_sessions USING btree (tenant_id);


--
-- Name: idx_staff_skills_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_skills_gin ON public.staff USING gin (skills);


--
-- Name: idx_staff_tags_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_tags_gin ON public.staff USING gin (tags);


--
-- Name: idx_staff_team_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_team_uuid ON public.staff USING btree (team_uuid);


--
-- Name: idx_staff_tenant_google_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_tenant_google_id ON public.staff USING btree (tenant_id, google_id) WHERE (google_id IS NOT NULL);


--
-- Name: idx_staff_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_staff_tenant_id ON public.staff USING btree (tenant_id);


--
-- Name: idx_staff_tenant_microsoft_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_tenant_microsoft_id ON public.staff USING btree (tenant_id, microsoft_id) WHERE (microsoft_id IS NOT NULL);


--
-- Name: idx_staff_tenant_okta_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_tenant_okta_id ON public.staff USING btree (tenant_id, okta_id) WHERE (okta_id IS NOT NULL);


--
-- Name: idx_teams_default_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_teams_default_role_id ON public.teams USING btree (default_role_id) WHERE (default_role_id IS NOT NULL);


--
-- Name: idx_teams_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_teams_deleted_at ON public.teams USING btree (deleted_at);


--
-- Name: idx_teams_department_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_teams_department_id ON public.teams USING btree (department_id);


--
-- Name: idx_teams_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_teams_is_active ON public.teams USING btree (is_active);


--
-- Name: idx_teams_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_teams_slug ON public.teams USING btree (tenant_id, slug) WHERE (deleted_at IS NULL);


--
-- Name: idx_teams_team_lead_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_teams_team_lead_id ON public.teams USING btree (team_lead_id);


--
-- Name: idx_teams_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_teams_tenant_id ON public.teams USING btree (tenant_id);


--
-- Name: idx_teams_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_teams_tenant_vendor ON public.teams USING btree (tenant_id, vendor_id);


--
-- Name: idx_teams_tenant_vendor_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_teams_tenant_vendor_code ON public.teams USING btree (tenant_id, COALESCE(vendor_id, ''::character varying), code) WHERE ((deleted_at IS NULL) AND (code IS NOT NULL));


--
-- Name: idx_teams_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_teams_vendor_id ON public.teams USING btree (vendor_id);


--
-- Name: idx_tenant_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_email ON public.staff USING btree (tenant_id, email) WHERE (deleted_at IS NULL);


--
-- Name: idx_tenant_employee_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_employee_id ON public.staff USING btree (tenant_id, employee_id) WHERE ((deleted_at IS NULL) AND (employee_id IS NOT NULL));


--
-- Name: idx_tenant_secrets_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_secrets_active ON public.tenant_secrets USING btree (tenant_id, is_active) WHERE (is_active = true);


--
-- Name: idx_tenant_secrets_expiring; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_secrets_expiring ON public.tenant_secrets USING btree (expires_at) WHERE (expires_at IS NOT NULL);


--
-- Name: idx_tenant_secrets_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_secrets_provider ON public.tenant_secrets USING btree (tenant_id, provider);


--
-- Name: idx_tenant_secrets_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_secrets_tenant ON public.tenant_secrets USING btree (tenant_id);


--
-- Name: idx_tenant_secrets_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_secrets_type ON public.tenant_secrets USING btree (tenant_id, secret_type);


--
-- Name: idx_tenant_sso_config_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tenant_sso_config_tenant ON public.tenant_sso_config USING btree (tenant_id);


--
-- Name: staff trigger_staff_password_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_staff_password_change BEFORE UPDATE ON public.staff FOR EACH ROW EXECUTE FUNCTION public.update_password_change_timestamp();


--
-- Name: departments update_departments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_departments_updated_at BEFORE UPDATE ON public.departments FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: employee_id_sequences update_employee_id_sequences_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_employee_id_sequences_updated_at BEFORE UPDATE ON public.employee_id_sequences FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: staff_documents update_staff_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_staff_documents_updated_at BEFORE UPDATE ON public.staff_documents FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: staff_emergency_contacts update_staff_emergency_contacts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_staff_emergency_contacts_updated_at BEFORE UPDATE ON public.staff_emergency_contacts FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: staff_roles update_staff_roles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_staff_roles_updated_at BEFORE UPDATE ON public.staff_roles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: staff update_staff_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_staff_updated_at BEFORE UPDATE ON public.staff FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: teams update_teams_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_teams_updated_at BEFORE UPDATE ON public.teams FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: departments departments_parent_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT departments_parent_department_id_fkey FOREIGN KEY (parent_department_id) REFERENCES public.departments(id) ON DELETE SET NULL;


--
-- Name: departments fk_departments_head; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departments
    ADD CONSTRAINT fk_departments_head FOREIGN KEY (department_head_id) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: staff_sessions fk_staff_sessions_staff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_sessions
    ADD CONSTRAINT fk_staff_sessions_staff FOREIGN KEY (staff_id) REFERENCES public.staff(id);


--
-- Name: teams fk_teams_lead; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT fk_teams_lead FOREIGN KEY (team_lead_id) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: staff staff_department_uuid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_department_uuid_fkey FOREIGN KEY (department_uuid) REFERENCES public.departments(id) ON DELETE SET NULL;


--
-- Name: staff_documents staff_documents_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_documents
    ADD CONSTRAINT staff_documents_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(id) ON DELETE CASCADE;


--
-- Name: staff_documents staff_documents_verified_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_documents
    ADD CONSTRAINT staff_documents_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: staff_emergency_contacts staff_emergency_contacts_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_emergency_contacts
    ADD CONSTRAINT staff_emergency_contacts_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(id) ON DELETE CASCADE;


--
-- Name: staff_invitations staff_invitations_sent_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_invitations
    ADD CONSTRAINT staff_invitations_sent_by_fkey FOREIGN KEY (sent_by) REFERENCES public.staff(id);


--
-- Name: staff_invitations staff_invitations_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_invitations
    ADD CONSTRAINT staff_invitations_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(id) ON DELETE CASCADE;


--
-- Name: staff staff_invited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES public.staff(id);


--
-- Name: staff_login_audit staff_login_audit_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_login_audit
    ADD CONSTRAINT staff_login_audit_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: staff staff_manager_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_manager_id_fkey FOREIGN KEY (manager_id) REFERENCES public.staff(id);


--
-- Name: staff_oauth_providers staff_oauth_providers_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_oauth_providers
    ADD CONSTRAINT staff_oauth_providers_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(id) ON DELETE CASCADE;


--
-- Name: staff_password_history staff_password_history_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_password_history
    ADD CONSTRAINT staff_password_history_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(id) ON DELETE CASCADE;


--
-- Name: staff_permissions staff_permissions_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_permissions
    ADD CONSTRAINT staff_permissions_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.permission_categories(id) ON DELETE CASCADE;


--
-- Name: staff_rbac_audit_log staff_rbac_audit_log_performed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_rbac_audit_log
    ADD CONSTRAINT staff_rbac_audit_log_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: staff_rbac_audit_log staff_rbac_audit_log_target_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_rbac_audit_log
    ADD CONSTRAINT staff_rbac_audit_log_target_staff_id_fkey FOREIGN KEY (target_staff_id) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: staff_role_assignments staff_role_assignments_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_role_assignments
    ADD CONSTRAINT staff_role_assignments_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: staff_role_assignments staff_role_assignments_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_role_assignments
    ADD CONSTRAINT staff_role_assignments_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.staff_roles(id) ON DELETE CASCADE;


--
-- Name: staff_role_assignments staff_role_assignments_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_role_assignments
    ADD CONSTRAINT staff_role_assignments_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(id) ON DELETE CASCADE;


--
-- Name: staff_role_permissions staff_role_permissions_permission_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_role_permissions
    ADD CONSTRAINT staff_role_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES public.staff_permissions(id) ON DELETE CASCADE;


--
-- Name: staff_role_permissions staff_role_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_role_permissions
    ADD CONSTRAINT staff_role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.staff_roles(id) ON DELETE CASCADE;


--
-- Name: staff_sessions staff_sessions_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_sessions
    ADD CONSTRAINT staff_sessions_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(id) ON DELETE CASCADE;


--
-- Name: staff staff_team_uuid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_team_uuid_fkey FOREIGN KEY (team_uuid) REFERENCES public.teams(id) ON DELETE SET NULL;


--
-- Name: teams teams_default_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_default_role_id_fkey FOREIGN KEY (default_role_id) REFERENCES public.staff_roles(id) ON DELETE SET NULL;


--
-- Name: teams teams_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.departments(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


