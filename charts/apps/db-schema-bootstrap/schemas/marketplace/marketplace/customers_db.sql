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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: abandoned_cart_recovery_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.abandoned_cart_recovery_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    abandoned_cart_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    attempt_type character varying(50) NOT NULL,
    attempt_number bigint NOT NULL,
    status character varying(20) NOT NULL,
    message_template character varying(100),
    discount_offered character varying(50),
    external_id character varying(255),
    sent_at timestamp with time zone NOT NULL,
    delivered_at timestamp with time zone,
    opened_at timestamp with time zone,
    clicked_at timestamp with time zone,
    created_at timestamp with time zone
);


--
-- Name: abandoned_cart_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.abandoned_cart_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    abandonment_threshold_minutes bigint DEFAULT 60,
    expiration_days bigint DEFAULT 30,
    enabled boolean DEFAULT true,
    first_reminder_hours bigint DEFAULT 1,
    second_reminder_hours bigint DEFAULT 24,
    third_reminder_hours bigint DEFAULT 72,
    max_reminders bigint DEFAULT 3,
    offer_discount_on_reminder bigint DEFAULT 2,
    discount_type character varying(20),
    discount_value numeric(10,2),
    discount_code character varying(50),
    reminder_email_template1 character varying(100),
    reminder_email_template2 character varying(100),
    reminder_email_template3 character varying(100),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: abandoned_carts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.abandoned_carts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    cart_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    items jsonb NOT NULL,
    subtotal numeric(12,2) NOT NULL,
    item_count bigint NOT NULL,
    customer_email character varying(255),
    customer_first_name character varying(100),
    customer_last_name character varying(100),
    abandoned_at timestamp with time zone NOT NULL,
    last_cart_activity timestamp with time zone NOT NULL,
    reminder_count bigint DEFAULT 0,
    last_reminder_at timestamp with time zone,
    next_reminder_at timestamp with time zone,
    recovered_at timestamp with time zone,
    recovered_order_id uuid,
    expired_at timestamp with time zone,
    recovery_source character varying(50),
    discount_used character varying(50),
    recovered_value numeric(12,2) DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: customer_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_addresses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    address_type character varying(20) DEFAULT 'SHIPPING'::character varying,
    is_default boolean DEFAULT false,
    label character varying(50),
    first_name character varying(100),
    last_name character varying(100),
    company character varying(255),
    address_line1 character varying(255) NOT NULL,
    address_line2 character varying(255),
    city character varying(100) NOT NULL,
    state character varying(100),
    postal_code character varying(20) NOT NULL,
    country character varying(2) NOT NULL,
    phone character varying(50),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: customer_carts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_carts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    items jsonb DEFAULT '[]'::jsonb,
    subtotal numeric(12,2) DEFAULT 0,
    item_count bigint DEFAULT 0,
    last_item_change timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamp without time zone,
    last_validated_at timestamp without time zone,
    has_unavailable_items boolean DEFAULT false,
    has_price_changes boolean DEFAULT false,
    unavailable_count bigint DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: customer_communications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_communications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    communication_type character varying(50) NOT NULL,
    direction character varying(20) NOT NULL,
    subject character varying(255),
    content text,
    status character varying(20) DEFAULT 'sent'::character varying,
    external_id character varying(255),
    created_at timestamp with time zone
);


--
-- Name: customer_list_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_list_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    list_id uuid NOT NULL,
    product_id uuid NOT NULL,
    product_name character varying(255),
    product_image character varying(500),
    product_price numeric(10,2),
    notes text,
    added_at timestamp with time zone DEFAULT now()
);


--
-- Name: customer_lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_lists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    customer_id uuid NOT NULL,
    name character varying(100) NOT NULL,
    slug character varying(100) NOT NULL,
    description text,
    is_default boolean DEFAULT false,
    item_count bigint DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: customer_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    note text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: customer_payment_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_payment_methods (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    payment_gateway character varying(50) NOT NULL,
    gateway_payment_method_id character varying(255) NOT NULL,
    payment_type character varying(20) NOT NULL,
    card_brand character varying(20),
    last_four character varying(4),
    expiry_month bigint,
    expiry_year bigint,
    is_default boolean DEFAULT false,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: customer_segment_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_segment_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    segment_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    added_automatically boolean DEFAULT false,
    created_at timestamp with time zone
);


--
-- Name: customer_segments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_segments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    rules jsonb,
    is_dynamic boolean DEFAULT false,
    is_active boolean DEFAULT true,
    customer_count bigint DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: customer_wishlist_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customer_wishlist_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    product_id character varying(255) NOT NULL,
    product_name character varying(255),
    product_price numeric(10,2),
    product_image character varying(500),
    added_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    user_id uuid,
    email character varying(255) NOT NULL,
    first_name character varying(100) NOT NULL,
    last_name character varying(100) NOT NULL,
    phone character varying(50),
    status character varying(20) DEFAULT 'ACTIVE'::character varying,
    customer_type character varying(20) DEFAULT 'RETAIL'::character varying,
    total_orders bigint DEFAULT 0,
    total_spent numeric(12,2) DEFAULT 0,
    average_order_value numeric(10,2) DEFAULT 0,
    lifetime_value numeric(12,2) DEFAULT 0,
    last_order_date timestamp with time zone,
    first_order_date timestamp with time zone,
    tags text[],
    notes text,
    marketing_opt_in boolean DEFAULT false,
    email_verified boolean DEFAULT false,
    verification_token character varying(255),
    verification_token_expires_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    lock_reason text,
    locked_at timestamp with time zone,
    locked_by uuid,
    unlock_reason text,
    unlocked_at timestamp with time zone,
    unlocked_by uuid,
    country character varying(100),
    country_code character varying(2)
);


--
-- Name: abandoned_cart_recovery_attempts abandoned_cart_recovery_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.abandoned_cart_recovery_attempts
    ADD CONSTRAINT abandoned_cart_recovery_attempts_pkey PRIMARY KEY (id);


--
-- Name: abandoned_cart_settings abandoned_cart_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.abandoned_cart_settings
    ADD CONSTRAINT abandoned_cart_settings_pkey PRIMARY KEY (id);


--
-- Name: abandoned_carts abandoned_carts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.abandoned_carts
    ADD CONSTRAINT abandoned_carts_pkey PRIMARY KEY (id);


--
-- Name: customer_addresses customer_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_addresses
    ADD CONSTRAINT customer_addresses_pkey PRIMARY KEY (id);


--
-- Name: customer_carts customer_carts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_carts
    ADD CONSTRAINT customer_carts_pkey PRIMARY KEY (id);


--
-- Name: customer_communications customer_communications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_communications
    ADD CONSTRAINT customer_communications_pkey PRIMARY KEY (id);


--
-- Name: customer_list_items customer_list_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_list_items
    ADD CONSTRAINT customer_list_items_pkey PRIMARY KEY (id);


--
-- Name: customer_lists customer_lists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_lists
    ADD CONSTRAINT customer_lists_pkey PRIMARY KEY (id);


--
-- Name: customer_notes customer_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_notes
    ADD CONSTRAINT customer_notes_pkey PRIMARY KEY (id);


--
-- Name: customer_payment_methods customer_payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_payment_methods
    ADD CONSTRAINT customer_payment_methods_pkey PRIMARY KEY (id);


--
-- Name: customer_segment_members customer_segment_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_segment_members
    ADD CONSTRAINT customer_segment_members_pkey PRIMARY KEY (id);


--
-- Name: customer_segments customer_segments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_segments
    ADD CONSTRAINT customer_segments_pkey PRIMARY KEY (id);


--
-- Name: customer_wishlist_items customer_wishlist_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_wishlist_items
    ADD CONSTRAINT customer_wishlist_items_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: idx_abandoned_cart_recovery_attempts_abandoned_cart_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_cart_recovery_attempts_abandoned_cart_id ON public.abandoned_cart_recovery_attempts USING btree (abandoned_cart_id);


--
-- Name: idx_abandoned_cart_recovery_attempts_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_cart_recovery_attempts_tenant_id ON public.abandoned_cart_recovery_attempts USING btree (tenant_id);


--
-- Name: idx_abandoned_cart_settings_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_abandoned_cart_settings_tenant_id ON public.abandoned_cart_settings USING btree (tenant_id);


--
-- Name: idx_abandoned_carts_cart_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_carts_cart_id ON public.abandoned_carts USING btree (cart_id);


--
-- Name: idx_abandoned_carts_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_carts_customer_id ON public.abandoned_carts USING btree (customer_id);


--
-- Name: idx_abandoned_carts_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_carts_deleted_at ON public.abandoned_carts USING btree (deleted_at);


--
-- Name: idx_abandoned_carts_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_abandoned_carts_tenant_id ON public.abandoned_carts USING btree (tenant_id);


--
-- Name: idx_customer_list_items_list_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customer_list_items_list_id ON public.customer_list_items USING btree (list_id);


--
-- Name: idx_customer_list_items_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customer_list_items_product_id ON public.customer_list_items USING btree (product_id);


--
-- Name: idx_customer_list_items_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_customer_list_items_unique ON public.customer_list_items USING btree (list_id, product_id);


--
-- Name: idx_customer_lists_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customer_lists_customer_id ON public.customer_lists USING btree (customer_id);


--
-- Name: idx_customer_lists_customer_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_customer_lists_customer_slug ON public.customer_lists USING btree (slug);


--
-- Name: idx_customer_lists_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customer_lists_tenant_id ON public.customer_lists USING btree (tenant_id);


--
-- Name: idx_customer_tenant_cart; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_customer_tenant_cart ON public.customer_carts USING btree (customer_id, tenant_id);


--
-- Name: idx_customer_wishlist_items_customer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customer_wishlist_items_customer_id ON public.customer_wishlist_items USING btree (customer_id);


--
-- Name: idx_customer_wishlist_items_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customer_wishlist_items_tenant_id ON public.customer_wishlist_items USING btree (tenant_id);


--
-- Name: idx_customers_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customers_deleted_at ON public.customers USING btree (deleted_at);


--
-- Name: idx_customers_tenant_country; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customers_tenant_country ON public.customers USING btree (country_code);


--
-- Name: idx_customers_tenant_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customers_tenant_created ON public.customers USING btree (tenant_id, created_at DESC);


--
-- Name: idx_customers_tenant_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_customers_tenant_email ON public.customers USING btree (tenant_id, email);


--
-- Name: idx_customers_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customers_tenant_id ON public.customers USING btree (tenant_id);


--
-- Name: idx_customers_tenant_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customers_tenant_status ON public.customers USING btree (tenant_id, status);


--
-- Name: idx_customers_tenant_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customers_tenant_user ON public.customers USING btree (tenant_id, user_id);


--
-- Name: idx_customers_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_customers_user_id ON public.customers USING btree (user_id);


--
-- Name: abandoned_carts fk_abandoned_carts_cart; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.abandoned_carts
    ADD CONSTRAINT fk_abandoned_carts_cart FOREIGN KEY (cart_id) REFERENCES public.customer_carts(id);


--
-- Name: abandoned_carts fk_abandoned_carts_customer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.abandoned_carts
    ADD CONSTRAINT fk_abandoned_carts_customer FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: customer_list_items fk_customer_lists_items; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_list_items
    ADD CONSTRAINT fk_customer_lists_items FOREIGN KEY (list_id) REFERENCES public.customer_lists(id) ON DELETE CASCADE;


--
-- Name: customer_addresses fk_customers_addresses; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_addresses
    ADD CONSTRAINT fk_customers_addresses FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: customer_payment_methods fk_customers_payment_methods; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_payment_methods
    ADD CONSTRAINT fk_customers_payment_methods FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


