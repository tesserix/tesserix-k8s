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
-- Name: coupon_usage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.coupon_usage (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    coupon_id uuid NOT NULL,
    user_id text NOT NULL,
    order_id text,
    vendor_id text,
    discount_amount numeric NOT NULL,
    order_value numeric NOT NULL,
    payment_method text,
    application_source text,
    metadata jsonb,
    used_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: coupons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.coupons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    created_by_id text NOT NULL,
    updated_by_id text NOT NULL,
    code text NOT NULL,
    description text,
    display_text text,
    image_url text,
    thumbnail_url text,
    scope text NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    priority text DEFAULT 'MEDIUM'::text NOT NULL,
    is_active boolean DEFAULT true,
    discount_type text NOT NULL,
    discount_value numeric NOT NULL,
    max_discount numeric,
    min_order_value numeric,
    max_discount_per_vendor numeric,
    max_usage_count bigint,
    current_usage_count bigint DEFAULT 0,
    max_usage_per_user bigint,
    max_usage_per_tenant bigint,
    max_usage_per_vendor bigint,
    first_time_user_only boolean DEFAULT false,
    min_item_count bigint,
    max_item_count bigint,
    excluded_tenants jsonb,
    excluded_vendors jsonb,
    category_ids jsonb,
    product_ids jsonb,
    user_group_ids jsonb,
    country_codes jsonb,
    region_codes jsonb,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone,
    days_of_week jsonb,
    time_windows jsonb,
    allowed_payment_methods jsonb,
    stackable_with_other boolean DEFAULT false,
    stackable_priority bigint DEFAULT 0,
    combination text DEFAULT 'NONE'::text,
    metadata jsonb,
    tags jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: coupon_usage coupon_usage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coupon_usage
    ADD CONSTRAINT coupon_usage_pkey PRIMARY KEY (id);


--
-- Name: coupons coupons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coupons
    ADD CONSTRAINT coupons_pkey PRIMARY KEY (id);


--
-- Name: idx_coupon_usage_coupon_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_coupon_usage_coupon_id ON public.coupon_usage USING btree (coupon_id);


--
-- Name: idx_coupon_usage_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_coupon_usage_tenant_id ON public.coupon_usage USING btree (tenant_id);


--
-- Name: idx_coupons_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_coupons_deleted_at ON public.coupons USING btree (deleted_at);


--
-- Name: idx_coupons_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_coupons_tenant_id ON public.coupons USING btree (tenant_id);


--
-- Name: idx_tenant_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_code ON public.coupons USING btree (code);


--
-- Name: coupon_usage fk_coupon_usage_coupon; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coupon_usage
    ADD CONSTRAINT fk_coupon_usage_coupon FOREIGN KEY (coupon_id) REFERENCES public.coupons(id);


--
-- PostgreSQL database dump complete
--


