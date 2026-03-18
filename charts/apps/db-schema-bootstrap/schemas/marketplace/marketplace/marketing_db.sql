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

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: abandoned_carts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.abandoned_carts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    customer_id uuid NOT NULL,
    session_id character varying(255),
    cart_items jsonb NOT NULL,
    total_amount numeric(15,2) NOT NULL,
    item_count bigint NOT NULL,
    status character varying(50) DEFAULT 'PENDING'::character varying NOT NULL,
    recovery_attempts bigint DEFAULT 0,
    last_reminder_sent timestamp with time zone,
    recovered_at timestamp with time zone,
    order_id uuid,
    recovered_amount numeric(15,2) DEFAULT 0,
    abandoned_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: campaign_recipients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.campaign_recipients (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    status character varying(50) DEFAULT 'PENDING'::character varying NOT NULL,
    sent_at timestamp with time zone,
    delivered_at timestamp with time zone,
    opened_at timestamp with time zone,
    clicked_at timestamp with time zone,
    converted_at timestamp with time zone,
    unsubscribed_at timestamp with time zone,
    error_message text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.campaigns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    type character varying(50) NOT NULL,
    channel character varying(50) NOT NULL,
    status character varying(50) DEFAULT 'DRAFT'::character varying NOT NULL,
    segment_id uuid,
    target_all boolean DEFAULT false,
    subject character varying(500),
    content text,
    template_id uuid,
    scheduled_at timestamp with time zone,
    sent_at timestamp with time zone,
    total_recipients bigint DEFAULT 0,
    sent bigint DEFAULT 0,
    delivered bigint DEFAULT 0,
    opened bigint DEFAULT 0,
    clicked bigint DEFAULT 0,
    converted bigint DEFAULT 0,
    unsubscribed bigint DEFAULT 0,
    failed bigint DEFAULT 0,
    revenue numeric(15,2) DEFAULT 0,
    metadata jsonb,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: coupon_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.coupon_codes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    code character varying(50) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    type character varying(50) NOT NULL,
    discount_value numeric(15,2) NOT NULL,
    max_discount numeric(15,2),
    min_order_amount numeric(15,2),
    max_order_amount numeric(15,2),
    applicable_products jsonb,
    applicable_categories jsonb,
    excluded_products jsonb,
    max_usage bigint DEFAULT 0,
    usage_per_customer bigint DEFAULT 1,
    current_usage bigint DEFAULT 0,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone NOT NULL,
    is_active boolean DEFAULT true,
    is_public boolean DEFAULT true,
    campaign_id uuid,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: coupon_usages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.coupon_usages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    coupon_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    order_id uuid NOT NULL,
    discount_amount numeric(15,2) NOT NULL,
    order_total numeric(15,2) NOT NULL,
    used_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: customer_loyalties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_loyalties (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    customer_id uuid NOT NULL,
    total_points bigint DEFAULT 0,
    available_points bigint DEFAULT 0,
    lifetime_points bigint DEFAULT 0,
    current_tier character varying(100),
    tier_since timestamp with time zone,
    referral_code character varying(20),
    referred_by uuid,
    last_earned timestamp with time zone,
    last_redeemed timestamp with time zone,
    joined_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: customer_segments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_segments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    type character varying(50) NOT NULL,
    rules jsonb NOT NULL,
    customer_count bigint DEFAULT 0,
    last_calculated timestamp with time zone,
    is_active boolean DEFAULT true,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: loyalty_programs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.loyalty_programs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    points_per_dollar numeric(10,2) DEFAULT 1 NOT NULL,
    minimum_points bigint DEFAULT 0,
    points_expiry bigint DEFAULT 365,
    tiers jsonb,
    is_active boolean DEFAULT true,
    signup_bonus bigint DEFAULT 0,
    birthday_bonus bigint DEFAULT 0,
    referral_bonus bigint DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: loyalty_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.loyalty_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    customer_id uuid NOT NULL,
    loyalty_id uuid NOT NULL,
    type character varying(50) NOT NULL,
    points bigint NOT NULL,
    description character varying(500),
    order_id uuid,
    reference_id uuid,
    reference_type character varying(50),
    expires_at timestamp with time zone,
    expired_at timestamp with time zone,
    created_at timestamp with time zone
);


--
-- Name: referrals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.referrals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(100) NOT NULL,
    referrer_id uuid NOT NULL,
    referrer_loyalty_id uuid NOT NULL,
    referred_id uuid NOT NULL,
    referred_loyalty_id uuid NOT NULL,
    referral_code character varying(20) NOT NULL,
    status character varying(50) DEFAULT 'PENDING'::character varying NOT NULL,
    referrer_bonus_points bigint DEFAULT 0,
    referred_bonus_points bigint DEFAULT 0,
    referrer_bonus_awarded_at timestamp with time zone,
    referred_bonus_awarded_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: abandoned_carts abandoned_carts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.abandoned_carts
    ADD CONSTRAINT abandoned_carts_pkey PRIMARY KEY (id);


--
-- Name: campaign_recipients campaign_recipients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_recipients
    ADD CONSTRAINT campaign_recipients_pkey PRIMARY KEY (id);


--
-- Name: campaigns campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_pkey PRIMARY KEY (id);


--
-- Name: coupon_codes coupon_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coupon_codes
    ADD CONSTRAINT coupon_codes_pkey PRIMARY KEY (id);


--
-- Name: coupon_usages coupon_usages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coupon_usages
    ADD CONSTRAINT coupon_usages_pkey PRIMARY KEY (id);


--
-- Name: customer_loyalties customer_loyalties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_loyalties
    ADD CONSTRAINT customer_loyalties_pkey PRIMARY KEY (id);


--
-- Name: customer_segments customer_segments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_segments
    ADD CONSTRAINT customer_segments_pkey PRIMARY KEY (id);


--
-- Name: loyalty_programs loyalty_programs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyalty_programs
    ADD CONSTRAINT loyalty_programs_pkey PRIMARY KEY (id);


--
-- Name: loyalty_transactions loyalty_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyalty_transactions
    ADD CONSTRAINT loyalty_transactions_pkey PRIMARY KEY (id);


--
-- Name: referrals referrals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.referrals
    ADD CONSTRAINT referrals_pkey PRIMARY KEY (id);


--
-- Name: coupon_usages uni_coupon_usages_order_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coupon_usages
    ADD CONSTRAINT uni_coupon_usages_order_id UNIQUE (order_id);


--
-- Name: loyalty_programs uni_loyalty_programs_tenant_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyalty_programs
    ADD CONSTRAINT uni_loyalty_programs_tenant_id UNIQUE (tenant_id);


--
-- Name: idx_abandoned_carts_abandoned_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_carts_abandoned_at ON public.abandoned_carts USING btree (abandoned_at);


--
-- Name: idx_abandoned_carts_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_carts_customer ON public.abandoned_carts USING btree (customer_id);


--
-- Name: idx_abandoned_carts_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_carts_expires_at ON public.abandoned_carts USING btree (expires_at);


--
-- Name: idx_abandoned_carts_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_carts_session_id ON public.abandoned_carts USING btree (session_id);


--
-- Name: idx_abandoned_carts_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_carts_tenant ON public.abandoned_carts USING btree (tenant_id);


--
-- Name: idx_campaigns_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_campaigns_deleted_at ON public.campaigns USING btree (deleted_at);


--
-- Name: idx_campaigns_segment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_campaigns_segment ON public.campaigns USING btree (segment_id);


--
-- Name: idx_campaigns_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_campaigns_tenant ON public.campaigns USING btree (tenant_id);


--
-- Name: idx_coupon_codes_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_coupon_codes_deleted_at ON public.coupon_codes USING btree (deleted_at);


--
-- Name: idx_coupon_usages_coupon_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_coupon_usages_coupon_id ON public.coupon_usages USING btree (coupon_id);


--
-- Name: idx_coupon_usages_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_coupon_usages_customer_id ON public.coupon_usages USING btree (customer_id);


--
-- Name: idx_coupon_usages_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_coupon_usages_tenant_id ON public.coupon_usages USING btree (tenant_id);


--
-- Name: idx_coupons_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_coupons_code ON public.coupon_codes USING btree (code);


--
-- Name: idx_coupons_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_coupons_tenant ON public.coupon_codes USING btree (tenant_id);


--
-- Name: idx_customer_loyalties_referral_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_customer_loyalties_referral_code ON public.customer_loyalties USING btree (referral_code);


--
-- Name: idx_customer_segments_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customer_segments_deleted_at ON public.customer_segments USING btree (deleted_at);


--
-- Name: idx_loyalty_programs_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_loyalty_programs_tenant_id ON public.loyalty_programs USING btree (tenant_id);


--
-- Name: idx_loyalty_referred_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_loyalty_referred_by ON public.customer_loyalties USING btree (referred_by);


--
-- Name: idx_loyalty_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_loyalty_tenant ON public.customer_loyalties USING btree (tenant_id);


--
-- Name: idx_loyalty_tenant_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_loyalty_tenant_customer ON public.customer_loyalties USING btree (customer_id);


--
-- Name: idx_loyalty_txn_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_loyalty_txn_customer ON public.loyalty_transactions USING btree (customer_id);


--
-- Name: idx_loyalty_txn_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_loyalty_txn_tenant ON public.loyalty_transactions USING btree (tenant_id);


--
-- Name: idx_recipients_campaign; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_recipients_campaign ON public.campaign_recipients USING btree (campaign_id);


--
-- Name: idx_recipients_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_recipients_customer ON public.campaign_recipients USING btree (customer_id);


--
-- Name: idx_referrals_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_referrals_code ON public.referrals USING btree (referral_code);


--
-- Name: idx_referrals_referred; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_referrals_referred ON public.referrals USING btree (referred_id);


--
-- Name: idx_referrals_referrer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_referrals_referrer ON public.referrals USING btree (referrer_id);


--
-- Name: idx_referrals_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_referrals_tenant ON public.referrals USING btree (tenant_id);


--
-- Name: idx_segments_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_segments_tenant ON public.customer_segments USING btree (tenant_id);


--
-- PostgreSQL database dump complete
--


