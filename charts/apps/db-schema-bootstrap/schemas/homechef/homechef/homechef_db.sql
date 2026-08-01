-- =============================================================================
-- homechef_db — schema (regenerated from the live database 2026-07-22).
--
-- This is a pg_dump --schema-only of the running homechef_db, which is the
-- authoritative schema (the app's GORM AutoMigrate had diverged from the old
-- hand-written SQL — e.g. countries had no `id` column). Filename is
-- `homechef_db.sql` so the bootstrap targets the EXISTING `homechef_db`
-- (skips CREATE DATABASE; the homechef role lacks CREATEDB and owns the db).
-- Re-applying is a no-op: every object already exists ("already exists" is
-- tolerated by the bootstrap; zero real errors). Seed/reference data is NOT
-- included (schema only) — it already lives in the db and is app-managed.
-- Regenerate with:
--   kubectl exec -n homechef <primary> -c postgres -- \
--     pg_dump -U postgres -d homechef_db --schema-only --no-owner --no-privileges
-- =============================================================================
--
-- PostgreSQL database dump
--

-- Dumped from database version 16.4 (Debian 16.4-1.pgdg110+2)
-- Dumped by pg_dump version 16.4 (Debian 16.4-1.pgdg110+2)

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
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_stat_statements IS 'track planning and execution statistics of all SQL statements executed';


--
-- Name: user_search(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_search(uname text) RETURNS TABLE(usename name, passwd text)
    LANGUAGE sql SECURITY DEFINER
    AS $_$SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=$1;$_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.addresses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    label text,
    line1 text NOT NULL,
    line2 text,
    city text NOT NULL,
    state text NOT NULL,
    postal_code text NOT NULL,
    country text DEFAULT 'US'::text,
    latitude numeric,
    longitude numeric,
    is_default boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    line1_enc text,
    line2_enc text
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    prefix text NOT NULL,
    key_hash text NOT NULL,
    scopes text,
    created_by uuid,
    last_used_at timestamp with time zone,
    expires_at timestamp with time zone,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone
);


--
-- Name: approval_request_histories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.approval_request_histories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    approval_id uuid NOT NULL,
    from_status character varying(30),
    to_status character varying(30) NOT NULL,
    changed_by_id uuid NOT NULL,
    notes text,
    created_at timestamp with time zone
);


--
-- Name: approval_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.approval_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    type character varying(50) NOT NULL,
    status character varying(30) DEFAULT 'pending'::character varying,
    priority character varying(20) DEFAULT 'normal'::character varying,
    chef_id uuid,
    partner_id uuid,
    submitted_by_id uuid NOT NULL,
    reviewed_by_id uuid,
    entity_type character varying(50),
    entity_id uuid,
    title text NOT NULL,
    description text,
    submitted_data jsonb,
    admin_notes text,
    reviewed_at timestamp with time zone,
    expires_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    reminder_count bigint DEFAULT 0 NOT NULL,
    last_reminded_at timestamp with time zone,
    escalated_at timestamp with time zone
);


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    action text NOT NULL,
    entity_type text,
    entity_id text,
    old_value text,
    new_value text,
    ip_address text,
    user_agent text,
    created_at timestamp with time zone,
    correlation_id text
);


--
-- Name: campaign_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaign_deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid NOT NULL,
    user_id uuid NOT NULL,
    channel character varying(10) NOT NULL,
    status character varying(10) DEFAULT 'pending'::character varying NOT NULL,
    failure_reason text,
    sent_at timestamp with time zone,
    opened_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaigns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(160) NOT NULL,
    status character varying(16) DEFAULT 'draft'::character varying NOT NULL,
    send_push boolean DEFAULT false NOT NULL,
    send_email boolean DEFAULT false NOT NULL,
    push_title character varying(120),
    push_body text,
    email_subject character varying(200),
    email_html text,
    segment text,
    scheduled_at timestamp with time zone,
    sent_at timestamp with time zone,
    created_by uuid,
    recipients bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: cancellation_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cancellation_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    status character varying(24) DEFAULT 'pending_vendor'::character varying,
    customer_reason text,
    vendor_reason character varying(32),
    refund_destination character varying(16),
    food_refund_paise bigint DEFAULT 0,
    delivery_refund_paise bigint DEFAULT 0,
    tax_refund_paise bigint DEFAULT 0,
    refund_total_paise bigint DEFAULT 0,
    vendor_kept_paise bigint DEFAULT 0,
    platform_kept_paise bigint DEFAULT 0,
    refund_executed boolean DEFAULT false,
    refund_ref character varying(64),
    disputed boolean DEFAULT false,
    dispute_reason text,
    admin_resolved_by uuid,
    admin_note text,
    vendor_respond_by timestamp with time zone,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: cart_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cart_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    cart_id uuid NOT NULL,
    menu_item_id uuid NOT NULL,
    quantity bigint DEFAULT 1 NOT NULL,
    notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: carts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.carts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    chef_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: catering_quotes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catering_quotes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying,
    proposed_menu text,
    menu_items text[],
    price_per_person numeric NOT NULL,
    total_price numeric NOT NULL,
    notes text,
    includes_setup boolean DEFAULT false,
    includes_serving boolean DEFAULT false,
    includes_cleanup boolean DEFAULT false,
    includes_equipment boolean DEFAULT false,
    valid_until timestamp with time zone,
    accepted_at timestamp with time zone,
    rejected_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deposit_amount numeric DEFAULT 0
);


--
-- Name: catering_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catering_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    status character varying(20) DEFAULT 'open'::character varying,
    event_type text NOT NULL,
    event_date timestamp with time zone NOT NULL,
    event_time text,
    guest_count bigint NOT NULL,
    budget numeric,
    cuisine_types text[],
    dietary_needs text[],
    menu_style text,
    description text,
    venue_name text,
    address_line1 text,
    address_line2 text,
    city text,
    state text,
    postal_code text,
    latitude numeric,
    longitude numeric,
    contact_name text,
    contact_phone text,
    contact_email text,
    quote_deadline timestamp with time zone,
    accepted_quote_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    deposit_amount numeric DEFAULT 0,
    deposit_status character varying(12) DEFAULT 'none'::character varying,
    razorpay_order_id text,
    razorpay_payment_id text,
    deposit_paid_at timestamp with time zone,
    completed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    address_line1_enc text,
    address_line2_enc text,
    contact_name_enc text,
    contact_phone_enc text,
    contact_phone_bidx text,
    contact_email_enc text,
    contact_email_bidx text
);


--
-- Name: chat_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chat_room_id uuid NOT NULL,
    sender_id uuid NOT NULL,
    sender_role character varying(20) NOT NULL,
    content text NOT NULL,
    original_length bigint NOT NULL,
    pi_idetected boolean DEFAULT false,
    pii_violations text[],
    message_type character varying(20) DEFAULT 'text'::character varying,
    is_read boolean DEFAULT false,
    created_at timestamp with time zone
);


--
-- Name: chat_rooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chat_rooms (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    type character varying(30) NOT NULL,
    customer_id uuid NOT NULL,
    counterparty_id uuid NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying,
    last_message_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: chef_capacity_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chef_capacity_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    cutoff_enabled boolean DEFAULT false,
    lunch_cutoff character varying(5),
    dinner_cutoff character varying(5),
    auto_sold_out boolean DEFAULT true,
    slots_enabled boolean DEFAULT false,
    lunch_slot_start character varying(5),
    lunch_slot_end character varying(5),
    dinner_slot_start character varying(5),
    dinner_slot_end character varying(5),
    lunch_slot_capacity bigint,
    dinner_slot_capacity bigint,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: chef_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chef_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    type character varying(50) NOT NULL,
    file_name text NOT NULL,
    file_path text NOT NULL,
    bucket text NOT NULL,
    content_type text,
    file_size bigint,
    status character varying(20) DEFAULT 'pending'::character varying,
    rejection_reason text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    expiry_date timestamp with time zone,
    image_p_hash character varying(16)
);


--
-- Name: chef_notification_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chef_notification_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    new_orders boolean DEFAULT true,
    payouts boolean DEFAULT true,
    customer_messages boolean DEFAULT true,
    promo boolean DEFAULT false,
    quiet_hours_enabled boolean DEFAULT false,
    quiet_hours_start character varying(5) DEFAULT '22:00'::character varying,
    quiet_hours_end character varying(5) DEFAULT '07:00'::character varying,
    timezone character varying(64) DEFAULT 'Asia/Kolkata'::character varying,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: chef_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chef_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    business_name text NOT NULL,
    description text,
    profile_image text,
    banner_image text,
    cuisines text[],
    specialties text[],
    prep_time text,
    minimum_order numeric DEFAULT 0,
    delivery_radius numeric DEFAULT 10,
    service_radius numeric DEFAULT 10,
    rating numeric DEFAULT 0,
    total_reviews bigint DEFAULT 0,
    total_orders bigint DEFAULT 0,
    is_verified boolean DEFAULT false,
    verified_at timestamp with time zone,
    is_active boolean DEFAULT true,
    accepting_orders boolean DEFAULT true,
    kitchen_photos text[],
    address_line1 text,
    address_line2 text,
    city text,
    state text,
    postal_code text,
    latitude numeric,
    longitude numeric,
    is_featured boolean DEFAULT false,
    featured_until timestamp with time zone,
    stripe_account_id text,
    razorpay_account_id text,
    razorpay_product_id text DEFAULT ''::text,
    razorpay_settlement_status text DEFAULT ''::text,
    razorpay_settlement_requirements text DEFAULT ''::text,
    razorpay_stakeholder_created boolean DEFAULT false,
    payout_auto_release character varying(8) DEFAULT ''::character varying,
    payout_auto_disburse character varying(8) DEFAULT ''::character varying,
    cashfree_vendor_id text DEFAULT ''::text,
    cashfree_vendor_status text DEFAULT ''::text,
    payout_method text DEFAULT ''::text,
    bank_account_number text DEFAULT ''::text,
    bank_ifsc text DEFAULT ''::text,
    bank_account_name text DEFAULT ''::text,
    upi_id text DEFAULT ''::text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    payment_provider character varying(20) DEFAULT 'razorpay'::character varying,
    payout_country character varying(2) DEFAULT 'IN'::character varying,
    stripe_charges_enabled boolean DEFAULT false,
    stripe_payouts_enabled boolean DEFAULT false,
    pan_number character varying(10),
    fssai_license_number character varying(14),
    gstin character varying(15),
    paused_until timestamp with time zone,
    fssai_override_until timestamp with time zone,
    fssai_override_reason text,
    fssai_override_by uuid,
    slug text,
    issue_count bigint DEFAULT 0,
    kitchen_type character varying(20) DEFAULT 'home_kitchen'::character varying,
    offers_pickup boolean DEFAULT false,
    offers_self_delivery boolean DEFAULT false,
    self_delivery_base_fee numeric DEFAULT 0,
    self_delivery_free_radius_km numeric DEFAULT 0,
    self_delivery_per_km numeric DEFAULT 0,
    self_delivery_max_fee numeric DEFAULT 0,
    self_delivery_max_distance_km numeric DEFAULT 0,
    auto_schedule_enabled boolean DEFAULT false,
    address_line1_enc text,
    address_line2_enc text
);


--
-- Name: chef_promotions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chef_promotions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying,
    amount numeric NOT NULL,
    currency character varying(3) NOT NULL,
    duration bigint NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    razorpay_order_id text,
    razorpay_payment_id text,
    payment_method text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: chef_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chef_schedules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    day_of_week bigint NOT NULL,
    open_time text,
    close_time text,
    is_closed boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: chef_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chef_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    auto_accept_orders boolean DEFAULT false,
    auto_accept_threshold numeric DEFAULT 0,
    push_new_order boolean DEFAULT true,
    push_order_update boolean DEFAULT true,
    email_daily_summary boolean DEFAULT true,
    email_weekly_report boolean DEFAULT true,
    sms_new_order boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: chef_slot_daily_bookings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chef_slot_daily_bookings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    slot character varying(8) NOT NULL,
    booking_date date NOT NULL,
    booked_qty bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: chef_subscription_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chef_subscription_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    enabled boolean DEFAULT false,
    slots text[],
    cadences text[],
    per_meal_price numeric DEFAULT 0,
    delivery_fee numeric DEFAULT 0,
    daily_capacity bigint DEFAULT 0,
    cutoff_time character varying(5) DEFAULT '21:00'::character varying,
    trial_enabled boolean DEFAULT false,
    trial_duration_days bigint DEFAULT 3,
    trial_price numeric DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: cities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cities (
    id character varying(80) NOT NULL,
    state_id character varying(10) NOT NULL,
    name character varying(100) NOT NULL,
    is_major boolean DEFAULT false,
    latitude numeric,
    longitude numeric,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: combo_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.combo_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    combo_id uuid NOT NULL,
    menu_item_id uuid NOT NULL,
    name text,
    quantity bigint DEFAULT 1,
    sort_order bigint DEFAULT 0,
    created_at timestamp with time zone
);


--
-- Name: countries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.countries (
    code character(2) NOT NULL,
    name character varying(100) NOT NULL,
    native_name character varying(100),
    calling_code character varying(10),
    currency_code character(3),
    flag_emoji character varying(10),
    region character varying(50),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: currencies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.currencies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code character varying(3) NOT NULL,
    name character varying(100) NOT NULL,
    symbol character varying(10) NOT NULL,
    decimal_places bigint DEFAULT 2,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone
);


--
-- Name: customer_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    date_of_birth timestamp with time zone,
    dietary_preferences text[],
    food_allergies text[],
    cuisine_preferences text[],
    spice_tolerance character varying(20),
    household_size character varying(10),
    onboarding_completed boolean DEFAULT false,
    onboarding_step bigint DEFAULT 0,
    preferred_currency character varying(3) DEFAULT 'INR'::character varying,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: daily_menu_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_menu_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    daily_menu_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    date date NOT NULL,
    slot character varying(10) NOT NULL,
    variant character varying(10) NOT NULL,
    name text NOT NULL,
    description text,
    price numeric DEFAULT 0,
    image_url text,
    dietary_tags text[],
    allergens text[],
    menu_item_id uuid,
    sort_order bigint DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    is_combo boolean DEFAULT false,
    combo_components text[]
);


--
-- Name: daily_menus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_menus (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    date date NOT NULL,
    is_published boolean DEFAULT false,
    published_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    delivery_partner_id uuid,
    status character varying(20) DEFAULT 'pending'::character varying,
    pickup_address_line1 text,
    pickup_address_city text,
    pickup_latitude numeric,
    pickup_longitude numeric,
    dropoff_address_line1 text,
    dropoff_address_city text,
    dropoff_latitude numeric,
    dropoff_longitude numeric,
    distance numeric,
    estimated_duration bigint,
    actual_duration bigint,
    attempt_number bigint DEFAULT 1,
    max_attempts bigint DEFAULT 3,
    failure_reason text,
    assignment_type character varying(20) DEFAULT 'manual'::character varying,
    assigned_by_id uuid,
    offer_expires_at timestamp with time zone,
    provider_id uuid,
    external_delivery_id text,
    external_tracking_id text,
    external_tracking_url text,
    provider_cost numeric DEFAULT 0,
    delivery_fee numeric DEFAULT 0,
    tip numeric DEFAULT 0,
    total_payout numeric DEFAULT 0,
    assigned_at timestamp with time zone,
    picked_up_at timestamp with time zone,
    delivered_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    cancel_reason text,
    rider_name text,
    rider_phone text,
    rider_latitude numeric,
    rider_longitude numeric,
    provider_status text,
    rider_name_enc text,
    rider_phone_enc text
);


--
-- Name: delivery_distance_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_distance_cache (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    cache_key character varying(80) NOT NULL,
    chef_lat numeric NOT NULL,
    chef_lng numeric NOT NULL,
    drop_lat numeric NOT NULL,
    drop_lng numeric NOT NULL,
    distance_km numeric NOT NULL,
    provider character varying(20),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: delivery_partner_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_partner_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    partner_id uuid NOT NULL,
    type character varying(50) NOT NULL,
    file_name text NOT NULL,
    file_path text NOT NULL,
    bucket text NOT NULL,
    content_type text,
    file_size bigint,
    status character varying(20) DEFAULT 'pending'::character varying,
    rejection_reason text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: delivery_partners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_partners (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    vehicle_type text,
    vehicle_number text,
    license_number text,
    is_verified boolean DEFAULT false,
    verified_at timestamp with time zone,
    is_active boolean DEFAULT true,
    is_online boolean DEFAULT false,
    current_latitude numeric,
    current_longitude numeric,
    rating numeric DEFAULT 0,
    total_deliveries bigint DEFAULT 0,
    total_reviews bigint DEFAULT 0,
    agent_type character varying(20) DEFAULT 'freelance'::character varying,
    employee_id text,
    shift_start timestamp with time zone,
    shift_end timestamp with time zone,
    max_concurrent bigint DEFAULT 1,
    acceptance_rate numeric DEFAULT 0,
    on_time_rate numeric DEFAULT 0,
    csat_score numeric DEFAULT 0,
    offered_count bigint DEFAULT 0,
    accepted_count bigint DEFAULT 0,
    completed_on_time bigint DEFAULT 0,
    verification_status character varying(20) DEFAULT 'pending'::character varying,
    verified_by_id uuid,
    rejection_reason text,
    city text,
    emergency_contact text,
    emergency_phone text,
    date_of_birth timestamp with time zone,
    vehicle_make text,
    vehicle_model text,
    vehicle_year bigint,
    vehicle_color text,
    has_delivery_box_space boolean DEFAULT false,
    bank_account_number text,
    bank_ifsc text,
    bank_account_name text,
    upi_id text,
    payout_method character varying(20),
    onboarding_step bigint DEFAULT 0,
    onboarding_complete boolean DEFAULT false,
    terms_accepted_at timestamp with time zone,
    referral_code text,
    referred_by_id uuid,
    stripe_account_id text,
    razorpay_account_id text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    payment_provider character varying(20) DEFAULT 'razorpay'::character varying,
    payout_country character varying(2) DEFAULT 'IN'::character varying,
    stripe_charges_enabled boolean DEFAULT false,
    stripe_payouts_enabled boolean DEFAULT false,
    emergency_contact_enc text,
    emergency_phone_enc text,
    emergency_phone_bidx text
);


--
-- Name: delivery_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_providers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    code text NOT NULL,
    description text,
    logo_url text,
    api_base_url text,
    api_key text,
    api_secret text,
    webhook_secret text,
    status_mapping jsonb DEFAULT '{}'::jsonb,
    supported_cities jsonb DEFAULT '[]'::jsonb,
    supported_countries jsonb DEFAULT '["IN"]'::jsonb,
    max_distance numeric DEFAULT 20,
    avg_pickup_time bigint DEFAULT 15,
    pricing_model character varying(20) DEFAULT 'per_delivery'::character varying,
    base_cost numeric DEFAULT 0,
    per_km_cost numeric DEFAULT 0,
    currency character varying(3) DEFAULT 'INR'::character varying,
    priority bigint DEFAULT 1,
    is_enabled boolean DEFAULT false,
    is_active boolean DEFAULT true,
    max_concurrent_deliveries bigint DEFAULT 100,
    daily_limit bigint DEFAULT 0,
    total_deliveries bigint DEFAULT 0,
    success_rate numeric DEFAULT 0,
    avg_delivery_time bigint DEFAULT 0,
    last_used_at timestamp with time zone,
    contact_name text,
    contact_email text,
    contact_phone text,
    notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: delivery_zones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_zones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    city character varying(100) NOT NULL,
    state character varying(100),
    country character varying(2) DEFAULT 'IN'::character varying,
    tier character varying(20) DEFAULT 'standard'::character varying,
    min_latitude numeric,
    max_latitude numeric,
    min_longitude numeric,
    max_longitude numeric,
    boundary jsonb DEFAULT '{}'::jsonb,
    currency character varying(3) DEFAULT 'INR'::character varying,
    base_fare numeric DEFAULT 0,
    per_km_rate numeric DEFAULT 0,
    minimum_fare numeric DEFAULT 0,
    surge_multiplier numeric DEFAULT 1,
    tip_enabled boolean DEFAULT true,
    default_tip_percent numeric DEFAULT 10,
    max_tip_amount numeric DEFAULT 0,
    driver_payout_percent numeric DEFAULT 100,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: dish_ratings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dish_ratings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    review_id uuid NOT NULL,
    menu_item_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    rating bigint NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: driver_referrals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.driver_referrals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    referrer_id uuid NOT NULL,
    referee_id uuid NOT NULL,
    referral_code text NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying,
    bonus_amount numeric DEFAULT 0,
    paid_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: earnings_ledgers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.earnings_ledgers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    subscriber_type character varying(10) NOT NULL,
    cycle_start timestamp with time zone NOT NULL,
    cycle_end timestamp with time zone NOT NULL,
    source character varying(20) NOT NULL,
    order_id uuid,
    delivery_id uuid,
    amount numeric NOT NULL,
    currency character varying(3) NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: email_verification_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_verification_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token character varying(255) NOT NULL,
    used_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: exchange_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exchange_rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    base_currency character varying(3) NOT NULL,
    target_currency character varying(3) NOT NULL,
    rate numeric NOT NULL,
    fetched_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: favorite_chefs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.favorite_chefs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: favorite_dishes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.favorite_dishes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    menu_item_id uuid NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: group_order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_order_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    group_order_id uuid NOT NULL,
    participant_id uuid NOT NULL,
    menu_item_id uuid NOT NULL,
    name text NOT NULL,
    price numeric NOT NULL,
    quantity bigint DEFAULT 1 NOT NULL,
    subtotal numeric NOT NULL,
    notes text,
    created_at timestamp with time zone
);


--
-- Name: group_order_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_order_participants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    group_order_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(8) DEFAULT 'guest'::character varying NOT NULL,
    display_name text,
    share_amount numeric DEFAULT 0,
    payment_status character varying(12) DEFAULT 'pending'::character varying,
    razorpay_order_id text,
    razorpay_payment_id text,
    refund_txn_id uuid,
    joined_at timestamp with time zone,
    updated_at timestamp with time zone,
    display_name_enc text
);


--
-- Name: group_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    host_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    type character varying(10) DEFAULT 'personal'::character varying NOT NULL,
    split_mode character varying(10) DEFAULT 'split'::character varying NOT NULL,
    title text,
    company_name text,
    join_token text NOT NULL,
    status character varying(12) DEFAULT 'open'::character varying NOT NULL,
    order_id uuid,
    payout_transfer_id text,
    delivery_address_line1 text,
    delivery_address_line2 text,
    delivery_address_city text,
    delivery_address_state text,
    delivery_address_postal_code text,
    delivery_address_country character varying(2) DEFAULT 'IN'::character varying,
    delivery_latitude numeric,
    delivery_longitude numeric,
    delivery_instructions text,
    currency character varying(3) DEFAULT 'INR'::character varying,
    subtotal numeric DEFAULT 0,
    delivery_fee numeric DEFAULT 0,
    service_fee numeric DEFAULT 0,
    tax numeric DEFAULT 0,
    tax_rate numeric DEFAULT 0,
    tax_name text,
    total numeric DEFAULT 0,
    scheduled_for timestamp with time zone,
    expires_at timestamp with time zone,
    locked_at timestamp with time zone,
    placed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    cancel_reason text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    payout_hold_status character varying(32) DEFAULT ''::character varying NOT NULL,
    customer_confirmed_at timestamp with time zone,
    delivered_at timestamp with time zone,
    payout_settled_at timestamp with time zone,
    payout_settle_attempts bigint DEFAULT 0,
    commission_rate numeric DEFAULT 0,
    delivery_address_line1_enc text,
    delivery_address_line2_enc text
);


--
-- Name: loyalty_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.loyalty_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    balance numeric DEFAULT 0 NOT NULL,
    lifetime_points numeric DEFAULT 0 NOT NULL,
    tier character varying(16) DEFAULT 'bronze'::character varying NOT NULL,
    current_streak bigint DEFAULT 0 NOT NULL,
    longest_streak bigint DEFAULT 0 NOT NULL,
    last_streak_day date,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: loyalty_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.loyalty_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    loyalty_account_id uuid NOT NULL,
    user_id uuid NOT NULL,
    type character varying(10) NOT NULL,
    source character varying(20) NOT NULL,
    points numeric NOT NULL,
    points_after numeric NOT NULL,
    order_id uuid,
    reason text,
    created_by uuid,
    idempotency_key character varying(160) NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: meal_plan_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meal_plan_days (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    meal_plan_id uuid NOT NULL,
    date timestamp with time zone NOT NULL,
    slot character varying(10) NOT NULL,
    variant character varying(10) NOT NULL,
    status character varying(12) DEFAULT 'requested'::character varying,
    weekly_menu_item_id uuid,
    dish_name text,
    price numeric DEFAULT 0,
    order_id uuid,
    payout_transfer_id text,
    prepared_at timestamp with time zone,
    delivered_at timestamp with time zone,
    refund_txn_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    payout_hold_status character varying(32) DEFAULT ''::character varying,
    customer_confirmed_at timestamp with time zone,
    payout_settled_at timestamp with time zone,
    payout_settle_attempts bigint DEFAULT 0,
    commission_rate numeric DEFAULT 0
);


--
-- Name: meal_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meal_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    meal_plan_number text NOT NULL,
    customer_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    status character varying(24) DEFAULT 'pending_chef'::character varying,
    start_date timestamp with time zone,
    end_date timestamp with time zone,
    subtotal numeric DEFAULT 0,
    tax numeric DEFAULT 0,
    total numeric NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying,
    escrow_payment_id text,
    razorpay_order_id text,
    chef_respond_by timestamp with time zone,
    customer_approve_by timestamp with time zone,
    confirmed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    cancel_reason text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: meal_subscription_fulfillments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meal_subscription_fulfillments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    meal_subscription_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    date timestamp with time zone NOT NULL,
    slot character varying(10) NOT NULL,
    dish_name text,
    price numeric DEFAULT 0,
    status character varying(12) DEFAULT 'scheduled'::character varying NOT NULL,
    order_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: meal_subscription_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meal_subscription_invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    meal_subscription_id uuid NOT NULL,
    invoice_number text NOT NULL,
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    cycle_amount numeric NOT NULL,
    credit_applied numeric DEFAULT 0,
    amount numeric NOT NULL,
    tax_amount numeric DEFAULT 0,
    total_amount numeric NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying,
    period_start timestamp with time zone NOT NULL,
    period_end timestamp with time zone NOT NULL,
    gateway_payment_id text,
    paid_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: meal_subscription_skips; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meal_subscription_skips (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    meal_subscription_id uuid NOT NULL,
    date timestamp with time zone NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: meal_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meal_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    slots text[],
    days integer[],
    variant character varying(10),
    cadence character varying(10),
    per_meal_price numeric DEFAULT 0,
    delivery_fee numeric DEFAULT 0,
    cycle_amount numeric NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying,
    status character varying(16) DEFAULT 'trialing'::character varying NOT NULL,
    current_period_start timestamp with time zone,
    current_period_end timestamp with time zone,
    credit_balance numeric DEFAULT 0,
    trial_id uuid,
    default_address_id uuid,
    payment_gateway character varying(20) DEFAULT 'razorpay'::character varying,
    gateway_sub_id text,
    paused_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    cancel_reason text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: meal_trials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meal_trials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    price numeric DEFAULT 0,
    duration_days bigint DEFAULT 0,
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    razorpay_order_id text,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: menu_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.menu_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    sort_order bigint DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: menu_item_daily_sales; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.menu_item_daily_sales (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    menu_item_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    sale_date date NOT NULL,
    sold_qty bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: menu_item_images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.menu_item_images (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    menu_item_id uuid NOT NULL,
    url text NOT NULL,
    is_primary boolean DEFAULT false,
    sort_order bigint DEFAULT 0,
    created_at timestamp with time zone
);


--
-- Name: menu_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.menu_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    category_id uuid,
    name text NOT NULL,
    description text,
    price numeric NOT NULL,
    compare_price numeric DEFAULT 0,
    image_url text,
    dietary_tags text[],
    allergens text[],
    ingredients text[],
    prep_time bigint,
    portion_size text,
    serves bigint DEFAULT 1,
    spice_level bigint DEFAULT 0,
    is_available boolean DEFAULT true,
    is_approved boolean DEFAULT false,
    is_featured boolean DEFAULT false,
    total_orders bigint DEFAULT 0,
    rating numeric DEFAULT 0,
    total_reviews bigint DEFAULT 0,
    sort_order bigint DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    is_veg boolean,
    hsn character varying(8) DEFAULT '996331'::character varying,
    daily_capacity bigint,
    is_combo boolean DEFAULT false,
    available_days integer[]
);


--
-- Name: modifier_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.modifier_groups (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    menu_item_id uuid NOT NULL,
    name text NOT NULL,
    required boolean DEFAULT false,
    min_select bigint DEFAULT 0,
    max_select bigint DEFAULT 1,
    sort_order bigint DEFAULT 0,
    created_at timestamp with time zone
);


--
-- Name: modifier_options; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.modifier_options (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    group_id uuid NOT NULL,
    name text NOT NULL,
    price_delta numeric DEFAULT 0,
    is_available boolean DEFAULT true,
    sort_order bigint DEFAULT 0,
    created_at timestamp with time zone
);


--
-- Name: notification_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    category character varying(32) NOT NULL,
    email_enabled boolean DEFAULT true,
    push_enabled boolean DEFAULT true,
    sms_enabled boolean DEFAULT false,
    updated_at timestamp with time zone,
    created_at timestamp with time zone
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    type text NOT NULL,
    title text NOT NULL,
    message text,
    data jsonb,
    is_read boolean DEFAULT false,
    read_at timestamp with time zone,
    created_at timestamp with time zone
);


--
-- Name: order_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    invoice_number text NOT NULL,
    customer_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    subtotal numeric NOT NULL,
    food_tax numeric DEFAULT 0,
    delivery_fee numeric DEFAULT 0,
    delivery_tax numeric DEFAULT 0,
    service_fee numeric DEFAULT 0,
    service_tax numeric DEFAULT 0,
    tip numeric DEFAULT 0,
    discount numeric DEFAULT 0,
    total_amount numeric NOT NULL,
    country_code character varying(2),
    currency character varying(3),
    tax_name text,
    food_tax_percent numeric DEFAULT 0,
    service_tax_percent numeric DEFAULT 0,
    delivery_tax_percent numeric DEFAULT 0,
    customer_name text,
    customer_email text,
    customer_phone text,
    customer_address text,
    chef_name text,
    chef_address text,
    company_name text,
    company_address text,
    company_tax_id text,
    line_items jsonb DEFAULT '[]'::jsonb,
    issued_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    customer_name_enc text,
    customer_email_enc text,
    customer_email_bidx text,
    customer_phone_enc text,
    customer_phone_bidx text,
    customer_address_enc text,
    chef_name_enc text,
    chef_address_enc text
);


--
-- Name: order_issues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_issues (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    reason character varying(20) NOT NULL,
    description text,
    photo_urls text[],
    affected_item_ids text[],
    requested_amount numeric DEFAULT 0,
    refund_amount numeric DEFAULT 0,
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    resolved_by uuid,
    resolved_at timestamp with time zone,
    refund_txn_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    meal_plan_day_id uuid
);


--
-- Name: order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    menu_item_id uuid NOT NULL,
    name text NOT NULL,
    price numeric NOT NULL,
    quantity bigint NOT NULL,
    subtotal numeric NOT NULL,
    notes text,
    created_at timestamp with time zone,
    is_cancelled boolean DEFAULT false,
    cancelled_reason character varying(40),
    cancelled_at timestamp with time zone,
    refund_id text,
    refund_amount numeric DEFAULT 0,
    modifiers jsonb DEFAULT '[]'::jsonb
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_number text NOT NULL,
    customer_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    delivery_id uuid,
    status character varying(20) DEFAULT 'pending'::character varying,
    payment_status character varying(20) DEFAULT 'pending'::character varying,
    payment_method text,
    subtotal numeric NOT NULL,
    delivery_fee numeric DEFAULT 0,
    service_fee numeric DEFAULT 0,
    tax numeric DEFAULT 0,
    tip numeric DEFAULT 0,
    chef_tip numeric DEFAULT 0,
    driver_tip numeric DEFAULT 0,
    discount numeric DEFAULT 0,
    total numeric NOT NULL,
    promo_code text,
    delivery_address_line1 text,
    delivery_address_line2 text,
    delivery_address_city text,
    delivery_address_state text,
    delivery_address_postal_code text,
    delivery_latitude numeric,
    delivery_longitude numeric,
    delivery_instructions text,
    estimated_prep_time bigint,
    estimated_delivery_time bigint,
    scheduled_for timestamp with time zone,
    accepted_at timestamp with time zone,
    prepared_at timestamp with time zone,
    picked_up_at timestamp with time zone,
    delivered_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    cancel_reason text,
    special_instructions text,
    stripe_payment_intent_id text,
    razorpay_order_id text,
    razorpay_payment_id text,
    refund_id text,
    refunded_at timestamp with time zone,
    refund_amount numeric DEFAULT 0,
    refund_reason text,
    refund_initiated_by character varying(20),
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    payment_provider character varying(20) DEFAULT 'razorpay'::character varying,
    tax_rate numeric DEFAULT 0,
    tax_name character varying(40) DEFAULT ''::character varying,
    currency character varying(3) DEFAULT 'INR'::character varying,
    delivery_address_country character varying(2) DEFAULT 'IN'::character varying,
    wallet_applied numeric DEFAULT 0,
    gateway_split_paise integer DEFAULT 0,
    delivery_slot character varying(8),
    chef_funded_discount numeric DEFAULT 0,
    fulfillment_type character varying(16) DEFAULT 'delivery'::character varying,
    ready_photo_url text,
    handover_photo_url text,
    payout_hold_status character varying(32) DEFAULT ''::character varying,
    customer_confirmed_at timestamp with time zone,
    payout_settled_at timestamp with time zone,
    payout_settle_attempts bigint DEFAULT 0,
    commission_rate numeric DEFAULT 0,
    accept_reminder_count bigint DEFAULT 0 NOT NULL,
    last_accept_reminder_at timestamp with time zone,
    requested_fulfillment_at timestamp with time zone,
    confirmed_fulfillment_at timestamp with time zone,
    fulfillment_time_status character varying(12),
    delivery_fee_final numeric,
    delivery_address_line1_enc text,
    delivery_address_line2_enc text
);


--
-- Name: outbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbox_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subject character varying(255) NOT NULL,
    msg_id character varying(64) NOT NULL,
    aggregate_type character varying(64),
    aggregate_id character varying(64),
    payload text NOT NULL,
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    attempts bigint DEFAULT 0 NOT NULL,
    last_error text,
    next_retry_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    published_at timestamp with time zone
);


--
-- Name: password_reset_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.password_reset_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    created_at timestamp with time zone
);


--
-- Name: payment_drifts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_drifts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    agg_type character varying(24) NOT NULL,
    agg_id uuid NOT NULL,
    kind character varying(40) NOT NULL,
    detail text,
    expected_paise bigint DEFAULT 0,
    gateway_paise bigint DEFAULT 0,
    detected_at timestamp with time zone,
    resolved_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: payment_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_methods (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    stripe_payment_id text NOT NULL,
    type text NOT NULL,
    last4 text,
    brand text,
    exp_month bigint,
    exp_year bigint,
    is_default boolean DEFAULT false,
    created_at timestamp with time zone
);


--
-- Name: platform_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    key text NOT NULL,
    value text,
    type text DEFAULT 'string'::text,
    updated_by uuid,
    updated_at timestamp with time zone
);


--
-- Name: post_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    user_id uuid NOT NULL,
    parent_id uuid,
    content text NOT NULL,
    is_hidden boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: post_likes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_likes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: postcodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.postcodes (
    code character varying(10) NOT NULL,
    city_id character varying(80) NOT NULL,
    area_name character varying(200),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: posts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.posts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    status character varying(20) DEFAULT 'published'::character varying,
    content text NOT NULL,
    images text[],
    hashtags text[],
    menu_item_id uuid,
    likes_count bigint DEFAULT 0,
    comments_count bigint DEFAULT 0,
    shares_count bigint DEFAULT 0,
    is_moderated boolean DEFAULT false,
    moderated_at timestamp with time zone,
    moderator_note text,
    contact_info_detected boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: preference_options; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.preference_options (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category character varying(50) NOT NULL,
    value character varying(50) NOT NULL,
    label character varying(100) NOT NULL,
    description character varying(255),
    sort_order bigint DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone
);


--
-- Name: processed_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.processed_events (
    consumer character varying(64) NOT NULL,
    msg_id character varying(64) NOT NULL,
    subject character varying(255),
    processed_at timestamp with time zone
);


--
-- Name: promo_code_usages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.promo_code_usages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    promo_code_id uuid NOT NULL,
    user_id uuid NOT NULL,
    order_id uuid,
    discount numeric NOT NULL,
    used_at timestamp with time zone,
    subscription_id uuid
);


--
-- Name: promo_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.promo_codes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    description text,
    discount_type character varying(20) NOT NULL,
    discount_value numeric NOT NULL,
    min_order_amount numeric DEFAULT 0,
    max_discount numeric DEFAULT 0,
    usage_limit bigint DEFAULT 0,
    usage_count bigint DEFAULT 0,
    per_user_limit bigint DEFAULT 0,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone,
    is_active boolean DEFAULT true,
    applicable_to character varying(30) DEFAULT 'all'::character varying,
    created_by_id uuid NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    funding_source character varying(16) DEFAULT 'platform'::character varying,
    chef_id uuid,
    budget_cap numeric DEFAULT 0,
    budget_spent numeric DEFAULT 0
);


--
-- Name: referral_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referral_codes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    code text NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: referrals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.referrals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    referrer_user_id uuid NOT NULL,
    referee_user_id uuid NOT NULL,
    code text NOT NULL,
    status character varying(12) DEFAULT 'pending'::character varying NOT NULL,
    order_id uuid,
    referrer_reward numeric DEFAULT 0,
    referee_reward numeric DEFAULT 0,
    rewarded_at timestamp with time zone,
    referee_device character varying(255),
    referee_ip character varying(64),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.refresh_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone,
    user_agent text,
    ip_address text,
    last_used_at timestamp with time zone
);


--
-- Name: refund_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.refund_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    provider character varying(20) NOT NULL,
    provider_payment_id character varying(64),
    provider_refund_id character varying(64),
    amount numeric NOT NULL,
    currency_code character(3) DEFAULT 'INR'::bpchar NOT NULL,
    status character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    reason character varying(200),
    idempotency_key character varying(64) NOT NULL,
    scope_id character varying(80) NOT NULL,
    actor character varying(64),
    failure_reason text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    completed_at timestamp with time zone
);


--
-- Name: reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    chef_id uuid NOT NULL,
    overall_rating bigint NOT NULL,
    food_rating bigint,
    delivery_rating bigint,
    value_rating bigint,
    title text,
    comment text,
    images text[],
    is_approved boolean DEFAULT true,
    is_hidden boolean DEFAULT false,
    hidden_reason text,
    chef_response text,
    chef_responded_at timestamp with time zone,
    helpful_count bigint DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    packaging_rating bigint,
    hygiene_rating bigint
);


--
-- Name: staff_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_invitations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    staff_role character varying(30) NOT NULL,
    department character varying(50),
    title character varying(100),
    token text NOT NULL,
    invited_by_id uuid NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying,
    message text,
    expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    accepted_by_id uuid,
    created_at timestamp with time zone,
    email_enc text,
    email_bidx text
);


--
-- Name: staff_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    staff_role character varying(30) NOT NULL,
    permissions jsonb DEFAULT '[]'::jsonb,
    department character varying(50),
    title character varying(100),
    invited_by_id uuid,
    is_active boolean DEFAULT true,
    joined_at timestamp with time zone,
    last_active_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.states (
    id character varying(10) NOT NULL,
    country_code character(2) NOT NULL,
    code character varying(10) NOT NULL,
    name character varying(100) NOT NULL,
    type character varying(20) DEFAULT 'state'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: subscription_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subscription_id uuid NOT NULL,
    invoice_number text NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying,
    amount numeric NOT NULL,
    currency character varying(3) NOT NULL,
    tax_amount numeric DEFAULT 0,
    total_amount numeric NOT NULL,
    period_start timestamp with time zone NOT NULL,
    period_end timestamp with time zone NOT NULL,
    earnings_at_generation numeric DEFAULT 0,
    payment_gateway character varying(20),
    gateway_payment_id text,
    gateway_order_id text,
    attempt_count bigint DEFAULT 0,
    max_attempts bigint DEFAULT 3,
    last_attempt_at timestamp with time zone,
    next_retry_at timestamp with time zone,
    paid_at timestamp with time zone,
    refunded_at timestamp with time zone,
    refund_amount numeric DEFAULT 0,
    failure_reason text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    subscriber_type character varying(10) NOT NULL,
    country_code character varying(3) NOT NULL,
    currency character varying(3) NOT NULL,
    billing_interval character varying(10) NOT NULL,
    status character varying(20) DEFAULT 'trial'::character varying,
    plan_amount numeric NOT NULL,
    trial_starts_at timestamp with time zone NOT NULL,
    trial_ends_at timestamp with time zone NOT NULL,
    current_period_start timestamp with time zone,
    current_period_end timestamp with time zone,
    billing_starts_at timestamp with time zone,
    grace_ends_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    cancel_reason text,
    refund_amount numeric DEFAULT 0,
    payment_gateway character varying(20),
    gateway_sub_id text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    tier character varying(10) DEFAULT 'standard'::character varying NOT NULL,
    promo_code_id uuid
);


--
-- Name: support_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ticket_id uuid NOT NULL,
    sender_id uuid NOT NULL,
    sender_role character varying(20) NOT NULL,
    content text NOT NULL,
    pi_idetected boolean DEFAULT false,
    is_internal boolean DEFAULT false,
    created_at timestamp with time zone
);


--
-- Name: support_tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_tickets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ticket_number text NOT NULL,
    reporter_id uuid NOT NULL,
    reporter_role character varying(20) NOT NULL,
    assigned_to_id uuid,
    order_id uuid,
    category character varying(30) NOT NULL,
    priority character varying(10) DEFAULT 'medium'::character varying,
    status character varying(30) DEFAULT 'open'::character varying,
    subject text NOT NULL,
    description text NOT NULL,
    resolution text,
    resolved_at timestamp with time zone,
    closed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: tax_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tax_rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    country_code character varying(2) NOT NULL,
    region character varying(10) DEFAULT ''::character varying,
    tax_name character varying(40) NOT NULL,
    rate numeric NOT NULL,
    inclusive boolean DEFAULT false,
    notes text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: tips; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tips (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    chef_amount numeric DEFAULT 0,
    rider_amount numeric DEFAULT 0,
    amount numeric NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying,
    chef_user_id uuid,
    rider_user_id uuid,
    status character varying(12) DEFAULT 'pending'::character varying,
    razorpay_order_id text,
    razorpay_payment_id text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    order_id uuid,
    type text NOT NULL,
    amount numeric NOT NULL,
    currency text DEFAULT 'USD'::text,
    status text DEFAULT 'pending'::text,
    stripe_id text,
    description text,
    created_at timestamp with time zone
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    password text,
    first_name text NOT NULL,
    last_name text NOT NULL,
    phone text,
    avatar text,
    role character varying(20) DEFAULT 'customer'::character varying,
    auth_provider character varying(20) DEFAULT 'email'::character varying,
    provider_id text,
    is_active boolean DEFAULT true,
    email_verified boolean DEFAULT false,
    phone_verified boolean DEFAULT false,
    fcm_token text,
    last_login_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    totp_enabled boolean DEFAULT false,
    totp_verified_at timestamp with time zone,
    gip_uid text,
    gip_tenant_id text,
    gip_provider text,
    auth_pool character varying(16),
    marketing_consent boolean DEFAULT false NOT NULL,
    marketing_consent_at timestamp with time zone,
    email_enc text,
    email_bidx text,
    first_name_enc text,
    last_name_enc text,
    phone_enc text,
    phone_bidx text
);


--
-- Name: wallet_txns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wallet_txns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    wallet_id uuid NOT NULL,
    user_id uuid NOT NULL,
    type character varying(10) NOT NULL,
    source character varying(20) NOT NULL,
    amount numeric NOT NULL,
    balance_after numeric NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying NOT NULL,
    order_id uuid,
    reason text,
    created_by uuid,
    idempotency_key character varying(160) NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: wallets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wallets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    balance numeric DEFAULT 0 NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: weekly_menu_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.weekly_menu_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    day_of_week bigint NOT NULL,
    slot character varying(10) NOT NULL,
    variant character varying(10) NOT NULL,
    name text NOT NULL,
    description text,
    price numeric DEFAULT 0,
    image_url text,
    dietary_tags text[],
    allergens text[],
    menu_item_id uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: weekly_menus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.weekly_menus (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    is_published boolean DEFAULT false,
    published_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: weekly_statements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.weekly_statements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    chef_id uuid NOT NULL,
    user_id uuid NOT NULL,
    week_start timestamp with time zone NOT NULL,
    week_end timestamp with time zone NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying,
    orders_count bigint DEFAULT 0,
    gross_revenue numeric DEFAULT 0,
    platform_commission numeric DEFAULT 0,
    cgst numeric DEFAULT 0,
    sgst numeric DEFAULT 0,
    igst numeric DEFAULT 0,
    tds numeric DEFAULT 0,
    net_payout numeric DEFAULT 0,
    created_at timestamp with time zone,
    status character varying(20) DEFAULT 'pending'::character varying,
    paid_at timestamp with time zone,
    payout_ref text
);


--
-- Name: winback_offers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.winback_offers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    audience_type character varying(16) NOT NULL,
    trigger character varying(32) NOT NULL,
    promo_code_id uuid NOT NULL,
    code character varying(32) NOT NULL,
    discount_percent numeric DEFAULT 0,
    status character varying(16) DEFAULT 'offered'::character varying NOT NULL,
    subscription_id uuid,
    offered_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    reactivated_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: addresses addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.addresses
    ADD CONSTRAINT addresses_pkey PRIMARY KEY (id);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: approval_request_histories approval_request_histories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_request_histories
    ADD CONSTRAINT approval_request_histories_pkey PRIMARY KEY (id);


--
-- Name: approval_requests approval_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: campaign_deliveries campaign_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_deliveries
    ADD CONSTRAINT campaign_deliveries_pkey PRIMARY KEY (id);


--
-- Name: campaigns campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_pkey PRIMARY KEY (id);


--
-- Name: cancellation_requests cancellation_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cancellation_requests
    ADD CONSTRAINT cancellation_requests_pkey PRIMARY KEY (id);


--
-- Name: cart_items cart_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cart_items
    ADD CONSTRAINT cart_items_pkey PRIMARY KEY (id);


--
-- Name: carts carts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.carts
    ADD CONSTRAINT carts_pkey PRIMARY KEY (id);


--
-- Name: catering_quotes catering_quotes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catering_quotes
    ADD CONSTRAINT catering_quotes_pkey PRIMARY KEY (id);


--
-- Name: catering_requests catering_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catering_requests
    ADD CONSTRAINT catering_requests_pkey PRIMARY KEY (id);


--
-- Name: chat_messages chat_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);


--
-- Name: chat_rooms chat_rooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chat_rooms
    ADD CONSTRAINT chat_rooms_pkey PRIMARY KEY (id);


--
-- Name: chef_capacity_settings chef_capacity_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chef_capacity_settings
    ADD CONSTRAINT chef_capacity_settings_pkey PRIMARY KEY (id);


--
-- Name: chef_documents chef_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chef_documents
    ADD CONSTRAINT chef_documents_pkey PRIMARY KEY (id);


--
-- Name: chef_notification_preferences chef_notification_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chef_notification_preferences
    ADD CONSTRAINT chef_notification_preferences_pkey PRIMARY KEY (id);


--
-- Name: chef_profiles chef_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chef_profiles
    ADD CONSTRAINT chef_profiles_pkey PRIMARY KEY (id);


--
-- Name: chef_promotions chef_promotions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chef_promotions
    ADD CONSTRAINT chef_promotions_pkey PRIMARY KEY (id);


--
-- Name: chef_schedules chef_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chef_schedules
    ADD CONSTRAINT chef_schedules_pkey PRIMARY KEY (id);


--
-- Name: chef_settings chef_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chef_settings
    ADD CONSTRAINT chef_settings_pkey PRIMARY KEY (id);


--
-- Name: chef_slot_daily_bookings chef_slot_daily_bookings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chef_slot_daily_bookings
    ADD CONSTRAINT chef_slot_daily_bookings_pkey PRIMARY KEY (id);


--
-- Name: chef_subscription_configs chef_subscription_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chef_subscription_configs
    ADD CONSTRAINT chef_subscription_configs_pkey PRIMARY KEY (id);


--
-- Name: cities cities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cities
    ADD CONSTRAINT cities_pkey PRIMARY KEY (id);


--
-- Name: combo_items combo_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.combo_items
    ADD CONSTRAINT combo_items_pkey PRIMARY KEY (id);


--
-- Name: countries countries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.countries
    ADD CONSTRAINT countries_pkey PRIMARY KEY (code);


--
-- Name: currencies currencies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.currencies
    ADD CONSTRAINT currencies_pkey PRIMARY KEY (id);


--
-- Name: customer_profiles customer_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_profiles
    ADD CONSTRAINT customer_profiles_pkey PRIMARY KEY (id);


--
-- Name: daily_menu_items daily_menu_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_menu_items
    ADD CONSTRAINT daily_menu_items_pkey PRIMARY KEY (id);


--
-- Name: daily_menus daily_menus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_menus
    ADD CONSTRAINT daily_menus_pkey PRIMARY KEY (id);


--
-- Name: deliveries deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_pkey PRIMARY KEY (id);


--
-- Name: delivery_distance_cache delivery_distance_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_distance_cache
    ADD CONSTRAINT delivery_distance_cache_pkey PRIMARY KEY (id);


--
-- Name: delivery_partner_documents delivery_partner_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_partner_documents
    ADD CONSTRAINT delivery_partner_documents_pkey PRIMARY KEY (id);


--
-- Name: delivery_partners delivery_partners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_partners
    ADD CONSTRAINT delivery_partners_pkey PRIMARY KEY (id);


--
-- Name: delivery_providers delivery_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_providers
    ADD CONSTRAINT delivery_providers_pkey PRIMARY KEY (id);


--
-- Name: delivery_zones delivery_zones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_zones
    ADD CONSTRAINT delivery_zones_pkey PRIMARY KEY (id);


--
-- Name: dish_ratings dish_ratings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dish_ratings
    ADD CONSTRAINT dish_ratings_pkey PRIMARY KEY (id);


--
-- Name: driver_referrals driver_referrals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.driver_referrals
    ADD CONSTRAINT driver_referrals_pkey PRIMARY KEY (id);


--
-- Name: earnings_ledgers earnings_ledgers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.earnings_ledgers
    ADD CONSTRAINT earnings_ledgers_pkey PRIMARY KEY (id);


--
-- Name: email_verification_tokens email_verification_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_verification_tokens
    ADD CONSTRAINT email_verification_tokens_pkey PRIMARY KEY (id);


--
-- Name: exchange_rates exchange_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT exchange_rates_pkey PRIMARY KEY (id);


--
-- Name: favorite_chefs favorite_chefs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favorite_chefs
    ADD CONSTRAINT favorite_chefs_pkey PRIMARY KEY (id);


--
-- Name: favorite_dishes favorite_dishes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.favorite_dishes
    ADD CONSTRAINT favorite_dishes_pkey PRIMARY KEY (id);


--
-- Name: group_order_items group_order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_order_items
    ADD CONSTRAINT group_order_items_pkey PRIMARY KEY (id);


--
-- Name: group_order_participants group_order_participants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_order_participants
    ADD CONSTRAINT group_order_participants_pkey PRIMARY KEY (id);


--
-- Name: group_orders group_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_orders
    ADD CONSTRAINT group_orders_pkey PRIMARY KEY (id);


--
-- Name: loyalty_accounts loyalty_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyalty_accounts
    ADD CONSTRAINT loyalty_accounts_pkey PRIMARY KEY (id);


--
-- Name: loyalty_transactions loyalty_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyalty_transactions
    ADD CONSTRAINT loyalty_transactions_pkey PRIMARY KEY (id);


--
-- Name: meal_plan_days meal_plan_days_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_plan_days
    ADD CONSTRAINT meal_plan_days_pkey PRIMARY KEY (id);


--
-- Name: meal_plans meal_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_plans
    ADD CONSTRAINT meal_plans_pkey PRIMARY KEY (id);


--
-- Name: meal_subscription_fulfillments meal_subscription_fulfillments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_subscription_fulfillments
    ADD CONSTRAINT meal_subscription_fulfillments_pkey PRIMARY KEY (id);


--
-- Name: meal_subscription_invoices meal_subscription_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_subscription_invoices
    ADD CONSTRAINT meal_subscription_invoices_pkey PRIMARY KEY (id);


--
-- Name: meal_subscription_skips meal_subscription_skips_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_subscription_skips
    ADD CONSTRAINT meal_subscription_skips_pkey PRIMARY KEY (id);


--
-- Name: meal_subscriptions meal_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_subscriptions
    ADD CONSTRAINT meal_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: meal_trials meal_trials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meal_trials
    ADD CONSTRAINT meal_trials_pkey PRIMARY KEY (id);


--
-- Name: menu_categories menu_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_categories
    ADD CONSTRAINT menu_categories_pkey PRIMARY KEY (id);


--
-- Name: menu_item_daily_sales menu_item_daily_sales_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_item_daily_sales
    ADD CONSTRAINT menu_item_daily_sales_pkey PRIMARY KEY (id);


--
-- Name: menu_item_images menu_item_images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_item_images
    ADD CONSTRAINT menu_item_images_pkey PRIMARY KEY (id);


--
-- Name: menu_items menu_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_items
    ADD CONSTRAINT menu_items_pkey PRIMARY KEY (id);


--
-- Name: modifier_groups modifier_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modifier_groups
    ADD CONSTRAINT modifier_groups_pkey PRIMARY KEY (id);


--
-- Name: modifier_options modifier_options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modifier_options
    ADD CONSTRAINT modifier_options_pkey PRIMARY KEY (id);


--
-- Name: notification_preferences notification_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: order_invoices order_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_invoices
    ADD CONSTRAINT order_invoices_pkey PRIMARY KEY (id);


--
-- Name: order_issues order_issues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_issues
    ADD CONSTRAINT order_issues_pkey PRIMARY KEY (id);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: outbox_events outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT outbox_events_pkey PRIMARY KEY (id);


--
-- Name: password_reset_tokens password_reset_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_pkey PRIMARY KEY (id);


--
-- Name: payment_drifts payment_drifts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_drifts
    ADD CONSTRAINT payment_drifts_pkey PRIMARY KEY (id);


--
-- Name: payment_methods payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_methods
    ADD CONSTRAINT payment_methods_pkey PRIMARY KEY (id);


--
-- Name: platform_settings platform_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_settings
    ADD CONSTRAINT platform_settings_pkey PRIMARY KEY (id);


--
-- Name: post_comments post_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_comments
    ADD CONSTRAINT post_comments_pkey PRIMARY KEY (id);


--
-- Name: post_likes post_likes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_likes
    ADD CONSTRAINT post_likes_pkey PRIMARY KEY (id);


--
-- Name: postcodes postcodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.postcodes
    ADD CONSTRAINT postcodes_pkey PRIMARY KEY (code);


--
-- Name: posts posts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posts
    ADD CONSTRAINT posts_pkey PRIMARY KEY (id);


--
-- Name: preference_options preference_options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.preference_options
    ADD CONSTRAINT preference_options_pkey PRIMARY KEY (id);


--
-- Name: processed_events processed_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_events
    ADD CONSTRAINT processed_events_pkey PRIMARY KEY (consumer, msg_id);


--
-- Name: promo_code_usages promo_code_usages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.promo_code_usages
    ADD CONSTRAINT promo_code_usages_pkey PRIMARY KEY (id);


--
-- Name: promo_codes promo_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.promo_codes
    ADD CONSTRAINT promo_codes_pkey PRIMARY KEY (id);


--
-- Name: referral_codes referral_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referral_codes
    ADD CONSTRAINT referral_codes_pkey PRIMARY KEY (id);


--
-- Name: referrals referrals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT referrals_pkey PRIMARY KEY (id);


--
-- Name: refresh_tokens refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens
    ADD CONSTRAINT refresh_tokens_pkey PRIMARY KEY (id);


--
-- Name: refund_transactions refund_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refund_transactions
    ADD CONSTRAINT refund_transactions_pkey PRIMARY KEY (id);


--
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (id);


--
-- Name: staff_invitations staff_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_invitations
    ADD CONSTRAINT staff_invitations_pkey PRIMARY KEY (id);


--
-- Name: staff_members staff_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_members
    ADD CONSTRAINT staff_members_pkey PRIMARY KEY (id);


--
-- Name: states states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.states
    ADD CONSTRAINT states_pkey PRIMARY KEY (id);


--
-- Name: subscription_invoices subscription_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscription_invoices
    ADD CONSTRAINT subscription_invoices_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: support_messages support_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_messages
    ADD CONSTRAINT support_messages_pkey PRIMARY KEY (id);


--
-- Name: support_tickets support_tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_tickets
    ADD CONSTRAINT support_tickets_pkey PRIMARY KEY (id);


--
-- Name: tax_rates tax_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_rates
    ADD CONSTRAINT tax_rates_pkey PRIMARY KEY (id);


--
-- Name: tips tips_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tips
    ADD CONSTRAINT tips_pkey PRIMARY KEY (id);


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: wallet_txns wallet_txns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wallet_txns
    ADD CONSTRAINT wallet_txns_pkey PRIMARY KEY (id);


--
-- Name: wallets wallets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wallets
    ADD CONSTRAINT wallets_pkey PRIMARY KEY (id);


--
-- Name: weekly_menu_items weekly_menu_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weekly_menu_items
    ADD CONSTRAINT weekly_menu_items_pkey PRIMARY KEY (id);


--
-- Name: weekly_menus weekly_menus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weekly_menus
    ADD CONSTRAINT weekly_menus_pkey PRIMARY KEY (id);


--
-- Name: weekly_statements weekly_statements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.weekly_statements
    ADD CONSTRAINT weekly_statements_pkey PRIMARY KEY (id);


--
-- Name: winback_offers winback_offers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.winback_offers
    ADD CONSTRAINT winback_offers_pkey PRIMARY KEY (id);


--
-- Name: idx_addresses_one_default_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_addresses_one_default_per_user ON public.addresses USING btree (user_id) WHERE is_default;


--
-- Name: idx_addresses_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_addresses_user_id ON public.addresses USING btree (user_id);


--
-- Name: idx_api_keys_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_keys_created_by ON public.api_keys USING btree (created_by);


--
-- Name: idx_api_keys_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_api_keys_key_hash ON public.api_keys USING btree (key_hash);


--
-- Name: idx_api_keys_prefix; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_keys_prefix ON public.api_keys USING btree (prefix);


--
-- Name: idx_approval_request_histories_approval_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_request_histories_approval_id ON public.approval_request_histories USING btree (approval_id);


--
-- Name: idx_approval_requests_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_requests_chef_id ON public.approval_requests USING btree (chef_id);


--
-- Name: idx_approval_requests_escalated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_requests_escalated_at ON public.approval_requests USING btree (escalated_at);


--
-- Name: idx_approval_requests_partner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_requests_partner_id ON public.approval_requests USING btree (partner_id);


--
-- Name: idx_approval_requests_reminder_count; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_requests_reminder_count ON public.approval_requests USING btree (reminder_count);


--
-- Name: idx_approval_requests_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_requests_status ON public.approval_requests USING btree (status);


--
-- Name: idx_approval_requests_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_approval_requests_type ON public.approval_requests USING btree (type);


--
-- Name: idx_audit_logs_correlation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_correlation_id ON public.audit_logs USING btree (correlation_id);


--
-- Name: idx_audit_logs_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_user_id ON public.audit_logs USING btree (user_id);


--
-- Name: idx_campaign_deliveries_campaign_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaign_deliveries_campaign_id ON public.campaign_deliveries USING btree (campaign_id);


--
-- Name: idx_campaign_deliveries_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaign_deliveries_status ON public.campaign_deliveries USING btree (status);


--
-- Name: idx_campaign_deliveries_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaign_deliveries_user_id ON public.campaign_deliveries USING btree (user_id);


--
-- Name: idx_campaign_delivery_cell; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_campaign_delivery_cell ON public.campaign_deliveries USING btree (campaign_id, user_id, channel);


--
-- Name: idx_campaigns_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaigns_deleted_at ON public.campaigns USING btree (deleted_at);


--
-- Name: idx_campaigns_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaigns_scheduled_at ON public.campaigns USING btree (scheduled_at);


--
-- Name: idx_campaigns_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaigns_status ON public.campaigns USING btree (status);


--
-- Name: idx_cancellation_requests_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cancellation_requests_chef_id ON public.cancellation_requests USING btree (chef_id);


--
-- Name: idx_cancellation_requests_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cancellation_requests_customer_id ON public.cancellation_requests USING btree (customer_id);


--
-- Name: idx_cancellation_requests_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_cancellation_requests_order_id ON public.cancellation_requests USING btree (order_id);


--
-- Name: idx_cancellation_requests_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cancellation_requests_status ON public.cancellation_requests USING btree (status);


--
-- Name: idx_cart_items_cart_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cart_items_cart_id ON public.cart_items USING btree (cart_id);


--
-- Name: idx_carts_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_carts_chef_id ON public.carts USING btree (chef_id);


--
-- Name: idx_carts_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_carts_user_id ON public.carts USING btree (user_id);


--
-- Name: idx_catering_quotes_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_catering_quotes_chef_id ON public.catering_quotes USING btree (chef_id);


--
-- Name: idx_catering_quotes_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_catering_quotes_request_id ON public.catering_quotes USING btree (request_id);


--
-- Name: idx_catering_requests_contact_email_bidx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_catering_requests_contact_email_bidx ON public.catering_requests USING btree (contact_email_bidx);


--
-- Name: idx_catering_requests_contact_phone_bidx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_catering_requests_contact_phone_bidx ON public.catering_requests USING btree (contact_phone_bidx);


--
-- Name: idx_catering_requests_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_catering_requests_customer_id ON public.catering_requests USING btree (customer_id);


--
-- Name: idx_catering_requests_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_catering_requests_deleted_at ON public.catering_requests USING btree (deleted_at);


--
-- Name: idx_chat_messages_chat_room_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_messages_chat_room_id ON public.chat_messages USING btree (chat_room_id);


--
-- Name: idx_chat_messages_sender_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_messages_sender_id ON public.chat_messages USING btree (sender_id);


--
-- Name: idx_chat_rooms_counterparty_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_rooms_counterparty_id ON public.chat_rooms USING btree (counterparty_id);


--
-- Name: idx_chat_rooms_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_rooms_customer_id ON public.chat_rooms USING btree (customer_id);


--
-- Name: idx_chat_rooms_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chat_rooms_order_id ON public.chat_rooms USING btree (order_id);


--
-- Name: idx_chef_capacity_settings_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_chef_capacity_settings_chef_id ON public.chef_capacity_settings USING btree (chef_id);


--
-- Name: idx_chef_doc_fssai; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chef_doc_fssai ON public.chef_documents USING btree (type, status, chef_id, expiry_date);


--
-- Name: idx_chef_documents_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chef_documents_chef_id ON public.chef_documents USING btree (chef_id);


--
-- Name: idx_chef_documents_image_p_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chef_documents_image_p_hash ON public.chef_documents USING btree (image_p_hash);


--
-- Name: idx_chef_documents_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chef_documents_type ON public.chef_documents USING btree (type);


--
-- Name: idx_chef_notification_preferences_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_chef_notification_preferences_chef_id ON public.chef_notification_preferences USING btree (chef_id);


--
-- Name: idx_chef_profiles_business_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_chef_profiles_business_name ON public.chef_profiles USING btree (business_name);


--
-- Name: idx_chef_profiles_fssai_override_until; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chef_profiles_fssai_override_until ON public.chef_profiles USING btree (fssai_override_until);


--
-- Name: idx_chef_profiles_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chef_profiles_slug ON public.chef_profiles USING btree (slug);


--
-- Name: idx_chef_profiles_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_chef_profiles_user_id ON public.chef_profiles USING btree (user_id);


--
-- Name: idx_chef_promotions_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chef_promotions_chef_id ON public.chef_promotions USING btree (chef_id);


--
-- Name: idx_chef_schedules_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_chef_schedules_chef_id ON public.chef_schedules USING btree (chef_id);


--
-- Name: idx_chef_settings_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_chef_settings_chef_id ON public.chef_settings USING btree (chef_id);


--
-- Name: idx_chef_slot_day; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_chef_slot_day ON public.chef_slot_daily_bookings USING btree (chef_id, slot, booking_date);


--
-- Name: idx_chef_subscription_configs_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_chef_subscription_configs_chef_id ON public.chef_subscription_configs USING btree (chef_id);


--
-- Name: idx_cities_state_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cities_state_id ON public.cities USING btree (state_id);


--
-- Name: idx_combo_items_combo_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_combo_items_combo_id ON public.combo_items USING btree (combo_id);


--
-- Name: idx_currencies_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_currencies_code ON public.currencies USING btree (code);


--
-- Name: idx_customer_profiles_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_customer_profiles_user_id ON public.customer_profiles USING btree (user_id);


--
-- Name: idx_daily_item_chef_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_daily_item_chef_date ON public.daily_menu_items USING btree (chef_id, date);


--
-- Name: idx_daily_menu_chef_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_daily_menu_chef_date_live ON public.daily_menus USING btree (chef_id, date) WHERE ((mode)::text = 'live'::text);
CREATE UNIQUE INDEX idx_daily_menu_chef_date_test ON public.daily_menus USING btree (chef_id, date, test_session_id) WHERE ((mode)::text = 'test'::text);


--
-- Name: idx_daily_menu_items_daily_menu_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_daily_menu_items_daily_menu_id ON public.daily_menu_items USING btree (daily_menu_id);


--
-- Name: idx_deliveries_delivery_partner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deliveries_delivery_partner_id ON public.deliveries USING btree (delivery_partner_id);


--
-- Name: idx_deliveries_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_deliveries_order_id ON public.deliveries USING btree (order_id);


--
-- Name: idx_delivery_distance_cache_cache_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_delivery_distance_cache_cache_key ON public.delivery_distance_cache USING btree (cache_key);


--
-- Name: idx_delivery_partner_documents_partner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_partner_documents_partner_id ON public.delivery_partner_documents USING btree (partner_id);


--
-- Name: idx_delivery_partner_documents_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_partner_documents_type ON public.delivery_partner_documents USING btree (type);


--
-- Name: idx_delivery_partners_emergency_phone_bidx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_partners_emergency_phone_bidx ON public.delivery_partners USING btree (emergency_phone_bidx);


--
-- Name: idx_delivery_partners_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_delivery_partners_user_id ON public.delivery_partners USING btree (user_id);


--
-- Name: idx_delivery_providers_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_delivery_providers_code ON public.delivery_providers USING btree (code);


--
-- Name: idx_delivery_providers_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_providers_deleted_at ON public.delivery_providers USING btree (deleted_at);


--
-- Name: idx_delivery_zones_city; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_zones_city ON public.delivery_zones USING btree (city);


--
-- Name: idx_delivery_zones_country; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_zones_country ON public.delivery_zones USING btree (country);


--
-- Name: idx_delivery_zones_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_zones_deleted_at ON public.delivery_zones USING btree (deleted_at);


--
-- Name: idx_dish_ratings_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dish_ratings_chef_id ON public.dish_ratings USING btree (chef_id);


--
-- Name: idx_dish_ratings_menu_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dish_ratings_menu_item_id ON public.dish_ratings USING btree (menu_item_id);


--
-- Name: idx_dish_ratings_review_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dish_ratings_review_id ON public.dish_ratings USING btree (review_id);


--
-- Name: idx_driver_referrals_referee_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_driver_referrals_referee_id ON public.driver_referrals USING btree (referee_id);


--
-- Name: idx_driver_referrals_referrer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_driver_referrals_referrer_id ON public.driver_referrals USING btree (referrer_id);


--
-- Name: idx_earnings_ledgers_subscription_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_earnings_ledgers_subscription_id ON public.earnings_ledgers USING btree (subscription_id);


--
-- Name: idx_earnings_user_cycle; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_earnings_user_cycle ON public.earnings_ledgers USING btree (user_id, cycle_start, cycle_end);


--
-- Name: idx_email_verification_tokens_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_email_verification_tokens_token ON public.email_verification_tokens USING btree (token);


--
-- Name: idx_email_verification_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_verification_tokens_user_id ON public.email_verification_tokens USING btree (user_id);


--
-- Name: idx_favorite_chefs_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_favorite_chefs_chef_id ON public.favorite_chefs USING btree (chef_id);


--
-- Name: idx_favorite_chefs_user_chef; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_favorite_chefs_user_chef ON public.favorite_chefs USING btree (user_id, chef_id);


--
-- Name: idx_favorite_dishes_menu_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_favorite_dishes_menu_item_id ON public.favorite_dishes USING btree (menu_item_id);


--
-- Name: idx_favorite_dishes_user_item; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_favorite_dishes_user_item ON public.favorite_dishes USING btree (user_id, menu_item_id);


--
-- Name: idx_group_order_items_group_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_order_items_group_order_id ON public.group_order_items USING btree (group_order_id);


--
-- Name: idx_group_order_items_participant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_order_items_participant_id ON public.group_order_items USING btree (participant_id);


--
-- Name: idx_group_order_participants_payment_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_order_participants_payment_status ON public.group_order_participants USING btree (payment_status);


--
-- Name: idx_group_orders_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_orders_chef_id ON public.group_orders USING btree (chef_id);


--
-- Name: idx_group_orders_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_orders_expires_at ON public.group_orders USING btree (expires_at);


--
-- Name: idx_group_orders_host_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_orders_host_id ON public.group_orders USING btree (host_id);


--
-- Name: idx_group_orders_join_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_group_orders_join_token ON public.group_orders USING btree (join_token);


--
-- Name: idx_group_orders_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_orders_order_id ON public.group_orders USING btree (order_id);


--
-- Name: idx_group_orders_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_orders_status ON public.group_orders USING btree (status);


--
-- Name: idx_group_participant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_group_participant ON public.group_order_participants USING btree (group_order_id, user_id);


--
-- Name: idx_item_day; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_item_day ON public.menu_item_daily_sales USING btree (menu_item_id, sale_date);


--
-- Name: idx_loyalty_accounts_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_loyalty_accounts_user_id ON public.loyalty_accounts USING btree (user_id);


--
-- Name: idx_loyalty_transactions_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_loyalty_transactions_idempotency_key ON public.loyalty_transactions USING btree (idempotency_key);


--
-- Name: idx_loyalty_transactions_loyalty_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_loyalty_transactions_loyalty_account_id ON public.loyalty_transactions USING btree (loyalty_account_id);


--
-- Name: idx_loyalty_transactions_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_loyalty_transactions_order_id ON public.loyalty_transactions USING btree (order_id);


--
-- Name: idx_loyalty_transactions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_loyalty_transactions_user_id ON public.loyalty_transactions USING btree (user_id);


--
-- Name: idx_meal_fulfill_cell; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_meal_fulfill_cell ON public.meal_subscription_fulfillments USING btree (meal_subscription_id, date, slot);


--
-- Name: idx_meal_plan_days_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_plan_days_date ON public.meal_plan_days USING btree (date);


--
-- Name: idx_meal_plan_days_meal_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_plan_days_meal_plan_id ON public.meal_plan_days USING btree (meal_plan_id);


--
-- Name: idx_meal_plan_days_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_plan_days_order_id ON public.meal_plan_days USING btree (order_id);


--
-- Name: idx_meal_plan_days_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_plan_days_status ON public.meal_plan_days USING btree (status);


--
-- Name: idx_meal_plans_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_plans_chef_id ON public.meal_plans USING btree (chef_id);


--
-- Name: idx_meal_plans_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_plans_customer_id ON public.meal_plans USING btree (customer_id);


--
-- Name: idx_meal_plans_end_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_plans_end_date ON public.meal_plans USING btree (end_date);


--
-- Name: idx_meal_plans_meal_plan_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_meal_plans_meal_plan_number ON public.meal_plans USING btree (meal_plan_number);


--
-- Name: idx_meal_plans_razorpay_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_meal_plans_razorpay_order_id ON public.meal_plans USING btree (razorpay_order_id) WHERE (razorpay_order_id <> ''::text);


--
-- Name: idx_meal_plans_start_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_plans_start_date ON public.meal_plans USING btree (start_date);


--
-- Name: idx_meal_plans_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_plans_status ON public.meal_plans USING btree (status);


--
-- Name: idx_meal_skip_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_meal_skip_date ON public.meal_subscription_skips USING btree (meal_subscription_id, date);


--
-- Name: idx_meal_sub_one_live; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_meal_sub_one_live ON public.meal_subscriptions USING btree (customer_id, chef_id) WHERE (((status)::text <> 'cancelled'::text) AND (deleted_at IS NULL));


--
-- Name: idx_meal_subscription_fulfillments_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscription_fulfillments_chef_id ON public.meal_subscription_fulfillments USING btree (chef_id);


--
-- Name: idx_meal_subscription_fulfillments_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscription_fulfillments_customer_id ON public.meal_subscription_fulfillments USING btree (customer_id);


--
-- Name: idx_meal_subscription_fulfillments_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscription_fulfillments_deleted_at ON public.meal_subscription_fulfillments USING btree (deleted_at);


--
-- Name: idx_meal_subscription_fulfillments_meal_subscription_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscription_fulfillments_meal_subscription_id ON public.meal_subscription_fulfillments USING btree (meal_subscription_id);


--
-- Name: idx_meal_subscription_fulfillments_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscription_fulfillments_order_id ON public.meal_subscription_fulfillments USING btree (order_id);


--
-- Name: idx_meal_subscription_fulfillments_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscription_fulfillments_status ON public.meal_subscription_fulfillments USING btree (status);


--
-- Name: idx_meal_subscription_invoices_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscription_invoices_deleted_at ON public.meal_subscription_invoices USING btree (deleted_at);


--
-- Name: idx_meal_subscription_invoices_invoice_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_meal_subscription_invoices_invoice_number ON public.meal_subscription_invoices USING btree (invoice_number);


--
-- Name: idx_meal_subscription_invoices_meal_subscription_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscription_invoices_meal_subscription_id ON public.meal_subscription_invoices USING btree (meal_subscription_id);


--
-- Name: idx_meal_subscriptions_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscriptions_chef_id ON public.meal_subscriptions USING btree (chef_id);


--
-- Name: idx_meal_subscriptions_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscriptions_customer_id ON public.meal_subscriptions USING btree (customer_id);


--
-- Name: idx_meal_subscriptions_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscriptions_deleted_at ON public.meal_subscriptions USING btree (deleted_at);


--
-- Name: idx_meal_subscriptions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_meal_subscriptions_status ON public.meal_subscriptions USING btree (status);


--
-- Name: idx_meal_trial_cust_chef; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_meal_trial_cust_chef ON public.meal_trials USING btree (customer_id, chef_id);


--
-- Name: idx_menu_categories_chef_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_menu_categories_chef_name ON public.menu_categories USING btree (chef_id, name);


--
-- Name: idx_menu_categories_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_menu_categories_deleted_at ON public.menu_categories USING btree (deleted_at);


--
-- Name: idx_menu_item_daily_sales_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_menu_item_daily_sales_chef_id ON public.menu_item_daily_sales USING btree (chef_id);


--
-- Name: idx_menu_item_images_menu_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_menu_item_images_menu_item_id ON public.menu_item_images USING btree (menu_item_id);


--
-- Name: idx_menu_items_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_menu_items_category_id ON public.menu_items USING btree (category_id);


--
-- Name: idx_menu_items_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_menu_items_chef_id ON public.menu_items USING btree (chef_id);


--
-- Name: idx_menu_items_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_menu_items_deleted_at ON public.menu_items USING btree (deleted_at);


--
-- Name: idx_modifier_groups_menu_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_modifier_groups_menu_item_id ON public.modifier_groups USING btree (menu_item_id);


--
-- Name: idx_modifier_options_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_modifier_options_group_id ON public.modifier_options USING btree (group_id);


--
-- Name: idx_notif_pref_user_cat; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_notif_pref_user_cat ON public.notification_preferences USING btree (user_id, category);


--
-- Name: idx_notifications_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_user_id ON public.notifications USING btree (user_id);


--
-- Name: idx_order_invoices_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_invoices_chef_id ON public.order_invoices USING btree (chef_id);


--
-- Name: idx_order_invoices_customer_email_bidx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_invoices_customer_email_bidx ON public.order_invoices USING btree (customer_email_bidx);


--
-- Name: idx_order_invoices_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_invoices_customer_id ON public.order_invoices USING btree (customer_id);


--
-- Name: idx_order_invoices_customer_phone_bidx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_invoices_customer_phone_bidx ON public.order_invoices USING btree (customer_phone_bidx);


--
-- Name: idx_order_invoices_invoice_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_order_invoices_invoice_number ON public.order_invoices USING btree (invoice_number);


--
-- Name: idx_order_invoices_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_order_invoices_order_id ON public.order_invoices USING btree (order_id);


--
-- Name: idx_order_issues_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_issues_chef_id ON public.order_issues USING btree (chef_id);


--
-- Name: idx_order_issues_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_issues_customer_id ON public.order_issues USING btree (customer_id);


--
-- Name: idx_order_issues_meal_plan_day_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_issues_meal_plan_day_id ON public.order_issues USING btree (meal_plan_day_id);


--
-- Name: idx_order_issues_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_issues_order_id ON public.order_issues USING btree (order_id);


--
-- Name: idx_order_items_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_items_order_id ON public.order_items USING btree (order_id);


--
-- Name: idx_orders_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_orders_chef_id ON public.orders USING btree (chef_id);


--
-- Name: idx_orders_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_orders_customer_id ON public.orders USING btree (customer_id);


--
-- Name: idx_orders_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_orders_deleted_at ON public.orders USING btree (deleted_at);


--
-- Name: idx_orders_delivery_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_orders_delivery_id ON public.orders USING btree (delivery_id);


--
-- Name: idx_orders_order_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_orders_order_number ON public.orders USING btree (order_number);


--
-- Name: idx_orders_razorpay_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_orders_razorpay_order_id ON public.orders USING btree (razorpay_order_id) WHERE (razorpay_order_id <> ''::text);


--
-- Name: idx_orders_razorpay_payment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_orders_razorpay_payment_id ON public.orders USING btree (razorpay_payment_id) WHERE (razorpay_payment_id <> ''::text);


--
-- Name: idx_orders_stripe_payment_intent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_orders_stripe_payment_intent_id ON public.orders USING btree (stripe_payment_intent_id) WHERE (stripe_payment_intent_id <> ''::text);


--
-- Name: idx_outbox_dispatch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outbox_dispatch ON public.outbox_events USING btree (status, next_retry_at);


--
-- Name: idx_outbox_events_aggregate_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outbox_events_aggregate_id ON public.outbox_events USING btree (aggregate_id);


--
-- Name: idx_outbox_events_aggregate_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outbox_events_aggregate_type ON public.outbox_events USING btree (aggregate_type);


--
-- Name: idx_outbox_events_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outbox_events_created_at ON public.outbox_events USING btree (created_at);


--
-- Name: idx_outbox_events_msg_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_outbox_events_msg_id ON public.outbox_events USING btree (msg_id);


--
-- Name: idx_password_reset_tokens_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_password_reset_tokens_token ON public.password_reset_tokens USING btree (token);


--
-- Name: idx_password_reset_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_password_reset_tokens_user_id ON public.password_reset_tokens USING btree (user_id);


--
-- Name: idx_payment_drift_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_drift_open ON public.payment_drifts USING btree (agg_type, agg_id, kind);


--
-- Name: idx_payment_methods_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_methods_user_id ON public.payment_methods USING btree (user_id);


--
-- Name: idx_platform_settings_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_platform_settings_key ON public.platform_settings USING btree (key);


--
-- Name: idx_post_comments_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_comments_parent_id ON public.post_comments USING btree (parent_id);


--
-- Name: idx_post_comments_post_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_comments_post_id ON public.post_comments USING btree (post_id);


--
-- Name: idx_post_comments_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_comments_user_id ON public.post_comments USING btree (user_id);


--
-- Name: idx_post_likes_post_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_likes_post_id ON public.post_likes USING btree (post_id);


--
-- Name: idx_post_likes_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_post_likes_user_id ON public.post_likes USING btree (user_id);


--
-- Name: idx_postcodes_city_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_postcodes_city_id ON public.postcodes USING btree (city_id);


--
-- Name: idx_posts_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_posts_chef_id ON public.posts USING btree (chef_id);


--
-- Name: idx_posts_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_posts_deleted_at ON public.posts USING btree (deleted_at);


--
-- Name: idx_preference_options_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_preference_options_category ON public.preference_options USING btree (category);


--
-- Name: idx_processed_events_processed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processed_events_processed_at ON public.processed_events USING btree (processed_at);


--
-- Name: idx_promo_code_usages_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promo_code_usages_order_id ON public.promo_code_usages USING btree (order_id);


--
-- Name: idx_promo_code_usages_promo_code_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promo_code_usages_promo_code_id ON public.promo_code_usages USING btree (promo_code_id);


--
-- Name: idx_promo_code_usages_subscription_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promo_code_usages_subscription_id ON public.promo_code_usages USING btree (subscription_id);


--
-- Name: idx_promo_code_usages_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promo_code_usages_user_id ON public.promo_code_usages USING btree (user_id);


--
-- Name: idx_promo_codes_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promo_codes_chef_id ON public.promo_codes USING btree (chef_id);


--
-- Name: idx_promo_codes_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_promo_codes_code ON public.promo_codes USING btree (code);


--
-- Name: idx_promo_codes_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_promo_codes_deleted_at ON public.promo_codes USING btree (deleted_at);


--
-- Name: idx_rate_pair; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rate_pair ON public.exchange_rates USING btree (base_currency, target_currency);


--
-- Name: idx_referral_codes_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_referral_codes_code ON public.referral_codes USING btree (code);


--
-- Name: idx_referral_codes_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_referral_codes_user_id ON public.referral_codes USING btree (user_id);


--
-- Name: idx_referrals_referee_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_referrals_referee_user_id ON public.referrals USING btree (referee_user_id);


--
-- Name: idx_referrals_referrer_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_referrals_referrer_user_id ON public.referrals USING btree (referrer_user_id);


--
-- Name: idx_refresh_tokens_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_refresh_tokens_token ON public.refresh_tokens USING btree (token);


--
-- Name: idx_refresh_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refresh_tokens_user_id ON public.refresh_tokens USING btree (user_id);


--
-- Name: idx_refund_transactions_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_refund_transactions_idempotency_key ON public.refund_transactions USING btree (idempotency_key);


--
-- Name: idx_refund_transactions_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refund_transactions_order_id ON public.refund_transactions USING btree (order_id);


--
-- Name: idx_refund_transactions_scope_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refund_transactions_scope_id ON public.refund_transactions USING btree (scope_id);


--
-- Name: idx_refund_transactions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refund_transactions_status ON public.refund_transactions USING btree (status);


--
-- Name: idx_reviews_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reviews_chef_id ON public.reviews USING btree (chef_id);


--
-- Name: idx_reviews_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reviews_customer_id ON public.reviews USING btree (customer_id);


--
-- Name: idx_reviews_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reviews_deleted_at ON public.reviews USING btree (deleted_at);


--
-- Name: idx_reviews_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_reviews_order_id ON public.reviews USING btree (order_id);


--
-- Name: idx_staff_invitations_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_staff_invitations_email ON public.staff_invitations USING btree (email);


--
-- Name: idx_staff_invitations_email_bidx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_staff_invitations_email_bidx ON public.staff_invitations USING btree (email_bidx);


--
-- Name: idx_staff_invitations_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_staff_invitations_token ON public.staff_invitations USING btree (token);


--
-- Name: idx_staff_members_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_staff_members_deleted_at ON public.staff_members USING btree (deleted_at);


--
-- Name: idx_staff_members_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_staff_members_user_id ON public.staff_members USING btree (user_id);


--
-- Name: idx_states_country_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_states_country_code ON public.states USING btree (country_code);


--
-- Name: idx_subscription_invoices_invoice_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_subscription_invoices_invoice_number ON public.subscription_invoices USING btree (invoice_number);


--
-- Name: idx_subscription_invoices_subscription_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscription_invoices_subscription_id ON public.subscription_invoices USING btree (subscription_id);


--
-- Name: idx_subscriptions_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscriptions_deleted_at ON public.subscriptions USING btree (deleted_at);


--
-- Name: idx_subscriptions_promo_code_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscriptions_promo_code_id ON public.subscriptions USING btree (promo_code_id);


--
-- Name: idx_subscriptions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscriptions_user_id ON public.subscriptions USING btree (user_id);


--
-- Name: idx_support_messages_ticket_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_support_messages_ticket_id ON public.support_messages USING btree (ticket_id);


--
-- Name: idx_support_tickets_assigned_to_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_support_tickets_assigned_to_id ON public.support_tickets USING btree (assigned_to_id);


--
-- Name: idx_support_tickets_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_support_tickets_deleted_at ON public.support_tickets USING btree (deleted_at);


--
-- Name: idx_support_tickets_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_support_tickets_order_id ON public.support_tickets USING btree (order_id);


--
-- Name: idx_support_tickets_reporter_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_support_tickets_reporter_id ON public.support_tickets USING btree (reporter_id);


--
-- Name: idx_support_tickets_ticket_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_support_tickets_ticket_number ON public.support_tickets USING btree (ticket_number);


--
-- Name: idx_tax_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tax_lookup ON public.tax_rates USING btree (country_code, region);


--
-- Name: idx_tips_chef_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tips_chef_user_id ON public.tips USING btree (chef_user_id);


--
-- Name: idx_tips_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tips_customer_id ON public.tips USING btree (customer_id);


--
-- Name: idx_tips_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tips_order_id ON public.tips USING btree (order_id);


--
-- Name: idx_tips_razorpay_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_tips_razorpay_order_id ON public.tips USING btree (razorpay_order_id);


--
-- Name: idx_tips_rider_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tips_rider_user_id ON public.tips USING btree (rider_user_id);


--
-- Name: idx_tips_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tips_status ON public.tips USING btree (status);


--
-- Name: idx_transactions_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_order_id ON public.transactions USING btree (order_id);


--
-- Name: idx_transactions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_user_id ON public.transactions USING btree (user_id);


--
-- Name: idx_users_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_deleted_at ON public.users USING btree (deleted_at);


--
-- Name: idx_users_email_bidx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_email_bidx ON public.users USING btree (email_bidx);


--
-- Name: idx_users_email_per_pool; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_email_per_pool ON public.users USING btree (lower(email), auth_pool) WHERE ((email IS NOT NULL) AND (auth_pool IS NOT NULL));


--
-- Name: idx_users_email_pool; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_email_pool ON public.users USING btree (email, auth_pool);


--
-- Name: idx_users_g_ip_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_g_ip_uid ON public.users USING btree (gip_uid);


--
-- Name: idx_users_gip_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_gip_uid ON public.users USING btree (gip_uid) WHERE (gip_uid IS NOT NULL);


--
-- Name: idx_users_phone_bidx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_phone_bidx ON public.users USING btree (phone_bidx);


--
-- Name: idx_wallet_txns_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_wallet_txns_idempotency_key ON public.wallet_txns USING btree (idempotency_key);


--
-- Name: idx_wallet_txns_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wallet_txns_order_id ON public.wallet_txns USING btree (order_id);


--
-- Name: idx_wallet_txns_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wallet_txns_user_id ON public.wallet_txns USING btree (user_id);


--
-- Name: idx_wallet_txns_wallet_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wallet_txns_wallet_id ON public.wallet_txns USING btree (wallet_id);


--
-- Name: idx_wallets_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_wallets_user_id ON public.wallets USING btree (user_id);


--
-- Name: idx_weekly_cell; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_weekly_cell_live ON public.weekly_menu_items USING btree (chef_id, day_of_week, slot, variant) WHERE ((mode)::text = 'live'::text);
CREATE UNIQUE INDEX idx_weekly_cell_test ON public.weekly_menu_items USING btree (chef_id, day_of_week, slot, variant, test_session_id) WHERE ((mode)::text = 'test'::text);


--
-- Name: idx_weekly_menus_chef_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_weekly_menus_chef_live ON public.weekly_menus USING btree (chef_id) WHERE ((mode)::text = 'live'::text);
CREATE UNIQUE INDEX idx_weekly_menus_chef_test ON public.weekly_menus USING btree (chef_id, test_session_id) WHERE ((mode)::text = 'test'::text);


--
-- Name: idx_weekly_statements_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_weekly_statements_status ON public.weekly_statements USING btree (status);


--
-- Name: idx_weekly_statements_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_weekly_statements_user_id ON public.weekly_statements USING btree (user_id);


--
-- Name: idx_weekly_stmt_chef_week; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_weekly_stmt_chef_week ON public.weekly_statements USING btree (chef_id, week_start);


--
-- Name: idx_winback_offers_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_winback_offers_deleted_at ON public.winback_offers USING btree (deleted_at);


--
-- Name: idx_winback_offers_offered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_winback_offers_offered_at ON public.winback_offers USING btree (offered_at);


--
-- Name: idx_winback_offers_promo_code_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_winback_offers_promo_code_id ON public.winback_offers USING btree (promo_code_id);


--
-- Name: idx_winback_offers_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_winback_offers_status ON public.winback_offers USING btree (status);


--
-- Name: idx_winback_offers_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_winback_offers_user_id ON public.winback_offers USING btree (user_id);


--
-- Name: idx_winback_one_open; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_winback_one_open ON public.winback_offers USING btree (user_id) WHERE ((status)::text = 'offered'::text);


--
-- Post-dump idempotent column additions.
--
-- The bootstrap applies each CREATE TABLE with ON_ERROR_STOP=0, so on an
-- EXISTING table the CREATE fails "already exists" and is skipped whole — any
-- column added inside the CREATE body above never reaches the live table.
-- These ALTERs are how new columns actually land on the running database; they
-- are no-ops once the column exists (IF NOT EXISTS) and are folded back into
-- the CREATE body on the next pg_dump regeneration.
--
-- Route settlement onboarding (Home-Chef-App #740/#741): a linked account can
-- receive Route transfers but only pays them out once a settlement bank account
-- is registered and Razorpay activates it. These columns record that state.
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS razorpay_product_id text DEFAULT ''::text;
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS razorpay_settlement_status text DEFAULT ''::text;
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS razorpay_settlement_requirements text DEFAULT ''::text;
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS razorpay_stakeholder_created boolean DEFAULT false;
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS payout_auto_release character varying(8) DEFAULT ''::character varying;
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS payout_auto_disburse character varying(8) DEFAULT ''::character varying;
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS cashfree_vendor_id text DEFAULT ''::text;
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS cashfree_vendor_status text DEFAULT ''::text;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS gateway_split_paise integer DEFAULT 0;

-- Weekly menu thali/combo (parity with daily_menu_items): a cell can be a
-- bundled set (combo_components) at one price instead of a single dish.
ALTER TABLE public.weekly_menu_items ADD COLUMN IF NOT EXISTS is_combo boolean DEFAULT false;
ALTER TABLE public.weekly_menu_items ADD COLUMN IF NOT EXISTS combo_components text[];

-- v2 meal-plan/group-order refund workflow (Home-Chef-App docs/meal-plan-refund-flow-design.md).
-- Sub-state fields on a skip_req day (Status is varchar(12), too short for the stage names):
-- refund_stage = pending_chef | pending_admin | resolved; chef_refund_choice = full | half | none;
-- refund_destination = wallet | source. Inert until MEALPLAN_REFUND_FLOW_V2_ENABLED.
ALTER TABLE public.meal_plan_days ADD COLUMN IF NOT EXISTS refund_stage character varying(16) DEFAULT ''::character varying;
ALTER TABLE public.meal_plan_days ADD COLUMN IF NOT EXISTS chef_refund_choice character varying(6) DEFAULT ''::character varying;
ALTER TABLE public.meal_plan_days ADD COLUMN IF NOT EXISTS refund_destination character varying(8) DEFAULT ''::character varying;

--
-- Wallet -> double-entry ledger (Home-Chef-App docs/wallet-ledger-plan.md). Runs in SHADOW
-- alongside the legacy float wallet (wallets/wallet_txns) until reconciliation is clean; gated by
-- the API flag LEDGER_SHADOW_ENABLED. Immutable + append-only: rows are never updated or deleted;
-- a correction posts a new reversing transaction. Money is paise (bigint), never float. Balance
-- invariant per transaction: SUM(debit) = SUM(credit). Idempotent DDL so the 30-min bootstrap is
-- a no-op once created.
--

CREATE TABLE IF NOT EXISTS public.ledger_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(64),
    idempotency_key character varying(200) NOT NULL,
    reason text,
    ref_type character varying(32),
    ref_id character varying(64),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ledger_transactions_pkey PRIMARY KEY (id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_ledger_transactions_idempotency_key ON public.ledger_transactions USING btree (idempotency_key);
CREATE INDEX IF NOT EXISTS idx_ledger_transactions_tenant_id ON public.ledger_transactions USING btree (tenant_id);
CREATE INDEX IF NOT EXISTS idx_ledger_transactions_ref_type ON public.ledger_transactions USING btree (ref_type);
CREATE INDEX IF NOT EXISTS idx_ledger_transactions_ref_id ON public.ledger_transactions USING btree (ref_id);

CREATE TABLE IF NOT EXISTS public.ledger_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    transaction_id uuid NOT NULL,
    account_kind character varying(32) NOT NULL,
    user_id uuid,
    direction character varying(6) NOT NULL,
    amount_minor bigint NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ledger_entries_pkey PRIMARY KEY (id),
    CONSTRAINT ledger_entries_amount_positive CHECK (amount_minor > 0),
    CONSTRAINT ledger_entries_direction_check CHECK (direction IN ('debit', 'credit')),
    CONSTRAINT ledger_entries_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES public.ledger_transactions(id)
);

CREATE INDEX IF NOT EXISTS idx_ledger_entries_transaction_id ON public.ledger_entries USING btree (transaction_id);
CREATE INDEX IF NOT EXISTS idx_ledger_entries_account_kind ON public.ledger_entries USING btree (account_kind);
CREATE INDEX IF NOT EXISTS idx_ledger_entries_user_id ON public.ledger_entries USING btree (user_id);

--
-- PostgreSQL database dump complete
--



--
-- Account lifecycle: deactivate / delete / restore
-- (Home-Chef-App docs/superpowers/specs/2026-07-25-account-lifecycle-design.md)
--
-- Required for iOS + Android store submission: Apple 5.1.1(v) and Google Play
-- both require in-app account deletion. Deleting sets users.deleted_at (the
-- existing soft-delete column) and stamps purge_after; the account-purge cron
-- hard-erases everything once purge_after elapses, 180 days later. Until then a
-- returning user who signs up on the same email is offered a restore.
--
-- purge_after is stored rather than derived from deleted_at so the sweeper can
-- index it, and so changing the retention window later does not retroactively
-- reinterpret rows deleted under the old one.
--
-- NOTE: idx_users_email_per_pool is deliberately NOT made partial on deleted_at.
-- The soft-deleted row keeping its (lower(email), auth_pool) slot is exactly
-- what forces a returning user through the restore handshake in UpsertUser
-- instead of silently creating a duplicate account.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS deactivated_at timestamp with time zone;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS purge_after timestamp with time zone;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS deletion_reason text DEFAULT ''::text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS restored_at timestamp with time zone;

-- Partial: only pending-deletion rows carry purge_after, so the sweeper's
-- "purge_after <= now()" scan stays a tiny index regardless of table size.
CREATE INDEX IF NOT EXISTS idx_users_purge_after ON public.users USING btree (purge_after)
    WHERE (purge_after IS NOT NULL);

--
-- Loyalty points: dated earn batches (Home-Chef-App loyalty phase 1).
--
-- Every point CREDIT writes one dated lot here (expires_at = earned_at + expiry_days).
-- Redeem/expiry/refund-reversal FIFO-consume points_remaining from the soonest-expiring
-- lots first; loyalty_accounts.balance stays the fast running total (= SUM of the
-- account's non-expired lots' points_remaining). Idempotent on idempotency_key so a
-- redelivered event or retried grant never writes a second lot.
--

CREATE TABLE IF NOT EXISTS public.loyalty_earn_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  source varchar(20) NOT NULL,
  points double precision NOT NULL,
  points_remaining double precision NOT NULL,
  earned_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  order_id uuid,
  idempotency_key varchar(160) NOT NULL,
  created_at timestamptz DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_loyalty_earn_batches_idem ON public.loyalty_earn_batches (idempotency_key);
CREATE INDEX IF NOT EXISTS ix_loyalty_earn_batches_user ON public.loyalty_earn_batches (user_id, expires_at);
CREATE INDEX IF NOT EXISTS ix_loyalty_earn_batches_expiry ON public.loyalty_earn_batches (expires_at) WHERE points_remaining > 0;

--
-- Checkout credits: per-order funding split.
--
-- wallet_applied already records the store credit applied at checkout. These add
-- the loyalty side plus the two *_refunded counters. The counters exist so that
-- repeated PARTIAL refunds cannot over-return a source: without them, two 60%
-- refunds would each compute 60% of the ORIGINAL slice and together hand back
-- 120% of what that rail actually funded.
--
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS loyalty_applied      numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS loyalty_points_spent numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS wallet_refunded      numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS loyalty_refunded     numeric(10,2) NOT NULL DEFAULT 0;

-- Serves the rolling 30-day monthly-redemption-cap window, which filters
-- loyalty_transactions by (user_id, type, source, created_at) on every checkout
-- quote — i.e. on every slider drag.
CREATE INDEX IF NOT EXISTS ix_loyalty_txn_redeem_window
  ON public.loyalty_transactions (user_id, created_at)
  WHERE type = 'debit' AND source IN ('redeem', 'order_redemption');

--
-- Login two-factor (opt-in) — see Home-Chef-App
-- docs/superpowers/specs/2026-07-25-login-otp-2fa-design.md
--
-- Opt-in per account, challenged on every fresh login from a device the user has
-- not chosen to remember. Delivered to the registered email (SendGrid→Resend) or
-- the registered phone (Firebase phone verification).
--
-- Nothing here is populated until MFA_ENABLED is on AND a user turns the feature
-- on for themselves, so these tables stay empty on deploy.
--

--
-- One row per user who has touched two-factor. A MISSING row is not an error —
-- the API reads absence as "never set up", which is the same as disabled.
--
-- enabled is separate from the two *_enrolled flags on purpose: enrolling a
-- channel must not arm the gate. A user who closes the tab halfway through setup
-- would otherwise be locked out with no backup codes issued.
--
-- The MFA phone is held HERE rather than reusing users.phone. Sharing that column
-- would mean editing a profile silently relocates the second factor, which is an
-- account-takeover path. Encrypted with the same envelope scheme as the other PII
-- columns, with a blind index for lookup.
--
CREATE TABLE IF NOT EXISTS public.user_mfa_settings (
  user_id         uuid PRIMARY KEY,
  enabled         boolean NOT NULL DEFAULT false,
  email_enrolled  boolean NOT NULL DEFAULT false,
  phone_enrolled  boolean NOT NULL DEFAULT false,
  phone_e164_enc  text,
  phone_e164_bidx text,
  enrolled_at     timestamptz,
  disabled_at     timestamptz,
  updated_at      timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_user_mfa_settings_phone_bidx
  ON public.user_mfa_settings (phone_e164_bidx);

--
-- Single-use recovery codes, for when both enrolled channels are out of reach.
--
-- Stored as HMAC-SHA256 under a server-side key (MFA_BACKUP_CODE_KEY), never as
-- a bare hash: codes are short enough for a human to type, so a plain digest of
-- a leaked table would fall to an offline brute force in seconds.
--
-- Regenerating DELETES the previous set rather than marking it superseded —
-- people regenerate precisely because they believe the old sheet leaked.
--
CREATE TABLE IF NOT EXISTS public.mfa_backup_codes (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL,
  code_hmac  text NOT NULL,
  used_at    timestamptz,
  created_at timestamptz DEFAULT now()
);
-- Serves the remaining-codes count, which runs on the settings screen and after
-- every redemption.
CREATE INDEX IF NOT EXISTS ix_mfa_backup_codes_unused
  ON public.mfa_backup_codes (user_id) WHERE used_at IS NULL;

--
-- Devices the user chose to remember, so the challenge does not repeat.
--
-- By product decision there is NO time-based expiry: trust ends only on explicit
-- revocation, on two-factor being switched off, or on a password change. That is
-- why revoked_at is nullable rather than there being an expires_at.
--
-- Scoped to one user AND one app, so a token lifted from the vendor app cannot
-- vouch for admin. token_hash is SHA-256 of a 256-bit random token that is
-- returned to the client exactly once and never stored; the unique index both
-- enforces that and serves the per-request lookup.
--
CREATE TABLE IF NOT EXISTS public.trusted_devices (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL,
  app          text NOT NULL,
  token_hash   text NOT NULL,
  label        text,
  platform     text,
  created_at   timestamptz DEFAULT now(),
  last_seen_at timestamptz DEFAULT now(),
  revoked_at   timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_trusted_devices_token
  ON public.trusted_devices (token_hash);
-- Serves the device list on the settings screen (active devices, newest first).
CREATE INDEX IF NOT EXISTS ix_trusted_devices_user_active
  ON public.trusted_devices (user_id, last_seen_at DESC) WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------------
-- Test chef mode: per-kitchen live/test partitioning with dual Razorpay slots.
--
-- Lets us exercise the full order → cook → deliver → pay → refund → payout flow
-- against PRODUCTION infrastructure without moving real money and without any
-- real customer ever seeing the sandbox kitchen. Also lets an admin flip an
-- established kitchen into a sandbox to reproduce a production issue against a
-- clone of its real setup, then flip back with its live data untouched.
--
-- Everything defaults to 'live', so applying this file changes nothing until an
-- admin explicitly marks a kitchen as test.
-- ---------------------------------------------------------------------------

ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS mode varchar(4) NOT NULL DEFAULT 'live';
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS first_live_at timestamptz;
ALTER TABLE public.chef_profiles ADD COLUMN IF NOT EXISTS active_test_session_id uuid;
CREATE INDEX IF NOT EXISTS ix_chef_profiles_mode ON public.chef_profiles (mode);

-- Backfill: every existing kitchen is live and has been since it was verified,
-- so it reads as ESTABLISHED (shown as closed if ever flipped to test) rather
-- than born-test (hidden outright). Without this an existing kitchen flipped to
-- test would vanish from its regulars' app instead of showing as closed.
UPDATE public.chef_profiles
   SET first_live_at = COALESCE(verified_at, created_at)
 WHERE first_live_at IS NULL AND mode = 'live';

-- Which live/test choice an admin made when approving a kitchen. Persisted on
-- the approval so the durable Temporal activation reads it back on retry.
ALTER TABLE public.approval_requests ADD COLUMN IF NOT EXISTS approved_mode varchar(4) DEFAULT 'live';

-- One debugging episode for one kitchen. Every live→test flip opens a new
-- numbered session with a fresh clone, so the evidence from a previous
-- investigation is never overwritten by the next one.
CREATE TABLE IF NOT EXISTS public.chef_test_sessions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chef_id           uuid NOT NULL,
  session_no        integer NOT NULL,
  status            varchar(10) NOT NULL DEFAULT 'open',
  reason            text DEFAULT '',
  order_window_days integer DEFAULT 30,
  cloned_at         timestamptz,
  clone_summary     jsonb DEFAULT '{}'::jsonb,
  opened_by_id      uuid,
  opened_at         timestamptz NOT NULL DEFAULT now(),
  closed_by_id      uuid,
  closed_at         timestamptz,
  purged_at         timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_chef_test_sessions_chef ON public.chef_test_sessions (chef_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_chef_test_sessions_chef_no
  ON public.chef_test_sessions (chef_id, session_no);

-- Aggregate counters per (kitchen, mode). chef_profiles keeps the LIVE numbers
-- so every customer-facing query reads them unchanged and a fake order can never
-- move a real rating; this table is what the vendor and admin dashboards read
-- for whichever mode is currently active.
CREATE TABLE IF NOT EXISTS public.chef_mode_stats (
  chef_id       uuid NOT NULL,
  mode          varchar(4) NOT NULL DEFAULT 'live',
  total_orders  integer NOT NULL DEFAULT 0,
  rating        double precision NOT NULL DEFAULT 0,
  total_reviews integer NOT NULL DEFAULT 0,
  issue_count   integer NOT NULL DEFAULT 0,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chef_id, mode)
);

-- The partition triple on every chef-scoped table.
--
--   mode            which world the row belongs to, snapshotted at creation and
--                   never changed — money operations read THIS, not the chef's
--                   current mode, so a refund still routes to the gateway that
--                   took the payment after a flip.
--   test_session_id which debugging session produced the row, so sessions can be
--                   listed and purged independently.
--   cloned_from_id  set on rows produced by the live→test clone. A clone is a
--                   replica of a REAL customer's order, so it must never surface
--                   to that customer.
--
-- The index is PARTIAL: the overwhelming majority of rows are live and are not
-- indexed at all, so the live hot path is unaffected.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'orders','order_items','group_orders','meal_plans','meal_plan_days',
    'meal_subscriptions','meal_trials','catering_requests','tips',
    'chef_promotions','reviews','menu_items','weekly_menus','weekly_menu_items',
    'daily_menus','daily_menu_items','chef_schedules'
  ] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS mode varchar(4) NOT NULL DEFAULT ''live''', t);
      EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS test_session_id uuid', t);
      EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS cloned_from_id uuid', t);
      EXECUTE format('CREATE INDEX IF NOT EXISTS ix_%s_mode ON public.%I (mode) WHERE mode <> ''live''', t, t);
      EXECUTE format('CREATE INDEX IF NOT EXISTS ix_%s_test_session ON public.%I (test_session_id) WHERE test_session_id IS NOT NULL', t, t);
    END IF;
  END LOOP;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- App Store / Play Store compliance (2026-07-26)
-- ─────────────────────────────────────────────────────────────────────────────

-- Sign in with Apple refresh token, held only so account deletion can call
-- Apple's /auth/revoke — required by App Review guideline 5.1.1(v). Deleting the
-- Identity Platform user does not touch Apple's own record of the grant, so
-- without this the app stays listed under Settings -> Apple ID -> Sign in with
-- Apple after the user deletes their account.
--
-- text, not varchar: the value is stored via models.EncryptedString, whose
-- prefixed-base64 ciphertext outgrows varchar(255). It is erased with the row by
-- the purge sweeper, and is deliberately excluded from the DPDP export.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS apple_refresh_token_enc text;

-- User-facing content moderation (App Review guideline 1.2).
--
-- Any app carrying user-generated content must let users report objectionable
-- content and block abusive users, and must actually filter what gets reported.
-- Home Chef's UGC surfaces are chef social posts, comments on them, customer
-- reviews, and order-scoped messaging; admin-side takedown tooling existed, but
-- nothing user-facing did.
--
-- content_reports is generic over target type rather than one table per surface:
-- the triage queue, rate limiting and audit trail are identical each time.
-- There is deliberately NO foreign key on target_id — the target lives in one of
-- several tables, and a report must outlive the content being deleted, which is
-- exactly the case an auditor asks about.
CREATE TABLE IF NOT EXISTS public.content_reports (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id     uuid NOT NULL,
  target_type     varchar(24) NOT NULL,
  target_id       uuid NOT NULL,
  -- Author of the reported content, resolved at report time. Denormalised so
  -- triage can rank authors by upheld reports without a per-type join, and so
  -- the report still names someone after the content row is gone.
  target_owner_id uuid,
  reason          varchar(24) NOT NULL,
  details         text,
  status          varchar(16) NOT NULL DEFAULT 'pending',
  reviewed_by     uuid,
  reviewed_at     timestamptz,
  resolution_note text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz
);

-- The auto-hide threshold counts distinct pending reporters per target, and the
-- triage queue filters by status — both are served by these.
CREATE INDEX IF NOT EXISTS ix_content_reports_target
  ON public.content_reports (target_type, target_id);
CREATE INDEX IF NOT EXISTS ix_content_reports_status
  ON public.content_reports (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_content_reports_reporter
  ON public.content_reports (reporter_id);
CREATE INDEX IF NOT EXISTS ix_content_reports_owner
  ON public.content_reports (target_owner_id) WHERE target_owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_content_reports_deleted_at
  ON public.content_reports (deleted_at);

-- user_blocks: one row per (blocker, blocked) pair.
--
-- Asymmetric by design — A blocking B hides B from A and stops B messaging A,
-- without telling B. The unique constraint makes BlockUser idempotent at the
-- database level, not just in application code.
CREATE TABLE IF NOT EXISTS public.user_blocks (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  blocker_id uuid NOT NULL,
  blocked_id uuid NOT NULL,
  reason     varchar(24),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_blocks_pair
  ON public.user_blocks (blocker_id, blocked_id);
-- Reverse lookup: the messaging gate checks both directions.
CREATE INDEX IF NOT EXISTS ix_user_blocks_blocked
  ON public.user_blocks (blocked_id);

-- meal_subscriptions.day_variants: per-day veg/non-veg choice.
--
-- `variant` holds a single value applied to every day of the plan, so a
-- household that wants veg midweek and non-veg at the weekend had to take one
-- or the other for the whole subscription. This column carries the per-day
-- override as a JSON object keyed by day-of-week (0=Sun .. 6=Sat), e.g.
--   {"1":"veg","2":"nonveg","6":"nonveg"}
--
-- `variant` is deliberately kept and still populated: it remains the fallback
-- for any day absent from this map, which keeps existing subscriptions and the
-- billing/preview paths working unchanged when day_variants is NULL.
ALTER TABLE public.meal_subscriptions
  ADD COLUMN IF NOT EXISTS day_variants jsonb;

-- ChefBook: long-form culinary blogging on top of the existing social posts.
--
-- `posts` was built for short updates — a single `content` field with images
-- and hashtags. ChefBook lets a chef publish an actual article (a title, a
-- cover image, a body long enough to be worth reading) without standing up a
-- parallel table that would duplicate likes, comments, moderation and the
-- feed query.
--
-- `kind` discriminates the two: 'post' keeps the existing short-form
-- behaviour and is the default, so every existing row stays exactly what it
-- was. 'blog' rows additionally carry title/cover_image and are the only ones
-- that render as articles.
ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS kind character varying(16) DEFAULT 'post' NOT NULL,
  ADD COLUMN IF NOT EXISTS title text,
  ADD COLUMN IF NOT EXISTS cover_image text,
  -- Estimated at write time from the body's word count so the feed doesn't
  -- have to re-derive it per render.
  ADD COLUMN IF NOT EXISTS reading_minutes integer DEFAULT 0 NOT NULL,
  -- ChefBook is restricted to food and cooking. The API refuses content with
  -- no culinary signal outright; this flags the borderline cases that were let
  -- through, so an admin can review rather than the check silently guessing.
  ADD COLUMN IF NOT EXISTS topic_flagged boolean DEFAULT false NOT NULL;

-- The feed lists published blogs newest-first; without this it degrades to a
-- full scan of every post ever written once ChefBook has any volume.
CREATE INDEX IF NOT EXISTS ix_posts_kind_created
  ON public.posts (kind, created_at DESC)
  WHERE deleted_at IS NULL;

-- Meal-plan platform fee + frozen GST rate (Home-Chef-App): a tiffin plan now charges
-- the customer-facing platform fee on the same basis as an à la carte order
-- (subtotal × PlatformFeePercent), so plan.total = subtotal + platform_fee + tax +
-- delivery. platform_fee MUST be stored, not derived: the per-day delivery share is
-- computed as total − subtotal − platform_fee − tax, and delivery is refundable on a
-- customer-initiated skip while the platform fee is not, so a missing column would
-- refund the platform's own fee on every skip.
--
-- tax_rate freezes the GST percent applied at booking. Without it the spawned per-day
-- orders stored a non-zero tax against rate 0 and the receipt rendered "IGST (0%)"
-- next to a real amount.
--
-- Both default 0, so existing plans keep their current totals untouched: an
-- already-booked plan has no platform fee and derives delivery exactly as before.
ALTER TABLE public.meal_plans
  ADD COLUMN IF NOT EXISTS platform_fee numeric DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tax_rate numeric DEFAULT 0;

-- Gateway on every charge, not just orders (Home-Chef-App): Cashfree is the
-- platform default, but only `orders` recorded which gateway took the money.
-- Meal plans, tips, catering deposits, group shares and promo purchases each
-- minted Razorpay directly, so nothing downstream could tell the rails apart.
--
-- Refunds are why this must be stored rather than inferred: a plan captured on
-- Cashfree refunded through the Razorpay rail fails, and the reverse strands the
-- money. The existing razorpay_order_id column already doubles as the generic
-- gateway order id (orders stamp the Cashfree order id into it), so only the
-- provider is missing.
--
-- Defaults to 'razorpay' so every already-captured row keeps refunding on the
-- rail that actually funded it; new rows are stamped by SelectCheckoutGateway.
ALTER TABLE public.meal_plans
  ADD COLUMN IF NOT EXISTS payment_provider character varying(20) DEFAULT 'razorpay'::character varying;
ALTER TABLE public.tips
  ADD COLUMN IF NOT EXISTS payment_provider character varying(20) DEFAULT 'razorpay'::character varying;
ALTER TABLE public.catering_requests
  ADD COLUMN IF NOT EXISTS payment_provider character varying(20) DEFAULT 'razorpay'::character varying;
ALTER TABLE public.chef_promotions
  ADD COLUMN IF NOT EXISTS payment_provider character varying(20) DEFAULT 'razorpay'::character varying;
ALTER TABLE public.group_order_participants
  ADD COLUMN IF NOT EXISTS payment_provider character varying(20) DEFAULT 'razorpay'::character varying;

--
-- Refund policy v3: the chef's decision window. A customer cancellation parks each unserved
-- day on the chef to price; past this the sweep agrees 100% so an unresponsive kitchen cannot
-- hold the customer's money indefinitely. Set only while refund_stage = 'pending_chef'.
ALTER TABLE public.meal_plan_days
  ADD COLUMN IF NOT EXISTS refund_decision_by timestamp with time zone;
CREATE INDEX IF NOT EXISTS idx_meal_plan_days_refund_decision_by
  ON public.meal_plan_days (refund_decision_by)
  WHERE refund_decision_by IS NOT NULL;

--
-- Stranded fulfilment: an order the chef ACCEPTED and never finished. Tracks the nudges sent
-- to both sides before the sweep refunds the customer in full. Distinct from the accept_*
-- columns, which chase an order nobody has taken yet.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS stale_reminder_count integer NOT NULL DEFAULT 0;
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS last_stale_reminder_at timestamp with time zone;
