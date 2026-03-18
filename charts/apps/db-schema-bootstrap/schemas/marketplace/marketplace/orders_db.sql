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
-- Name: cancellation_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.cancellation_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    storefront_id character varying(255),
    enabled boolean DEFAULT true,
    require_reason boolean DEFAULT true,
    allow_partial_cancellation boolean DEFAULT false,
    default_fee_type character varying(20) DEFAULT 'percentage'::character varying,
    default_fee_value numeric DEFAULT 15,
    refund_method character varying(50) DEFAULT 'original_payment'::character varying,
    auto_refund_enabled boolean DEFAULT true,
    non_cancellable_statuses jsonb DEFAULT '["SHIPPED", "DELIVERED"]'::jsonb,
    cancellation_windows jsonb DEFAULT '[]'::jsonb,
    cancellation_reasons jsonb DEFAULT '[]'::jsonb,
    require_approval_for_policy_changes boolean DEFAULT false,
    policy_text text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_by character varying(255),
    updated_by character varying(255)
);


--
-- Name: order_customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.order_customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    first_name text NOT NULL,
    last_name text NOT NULL,
    email text NOT NULL,
    phone text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: order_discounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.order_discounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    coupon_id uuid,
    coupon_code text,
    discount_type text NOT NULL,
    amount numeric(10,2) NOT NULL,
    description text,
    created_at timestamp with time zone
);


--
-- Name: order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.order_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    vendor_id character varying(255),
    product_id uuid NOT NULL,
    product_name text NOT NULL,
    sku text NOT NULL,
    image character varying(500),
    quantity bigint NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    total_price numeric(10,2) NOT NULL,
    tax_amount numeric(10,2) DEFAULT 0,
    tax_rate numeric(5,2) DEFAULT 0,
    hsn_code character varying(10),
    sac_code character varying(10),
    gst_slab numeric(5,2),
    cgst_amount numeric(10,2) DEFAULT 0,
    sgst_amount numeric(10,2) DEFAULT 0,
    igst_amount numeric(10,2) DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: order_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.order_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    method text NOT NULL,
    status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    amount numeric(10,2) NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying NOT NULL,
    transaction_id text,
    processed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: order_refunds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.order_refunds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    reason text NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    processed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: order_shippings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.order_shippings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    method text NOT NULL,
    carrier text,
    courier_service_code text,
    tracking_number text,
    cost numeric(10,2) NOT NULL,
    package_weight numeric(10,3) DEFAULT 0,
    package_length numeric(10,2) DEFAULT 0,
    package_width numeric(10,2) DEFAULT 0,
    package_height numeric(10,2) DEFAULT 0,
    base_rate numeric(10,2) DEFAULT 0,
    markup_amount numeric(10,2) DEFAULT 0,
    markup_percent numeric(5,2) DEFAULT 0,
    street text NOT NULL,
    city text NOT NULL,
    state text NOT NULL,
    state_code text,
    postal_code text NOT NULL,
    country text NOT NULL,
    country_code text,
    estimated_delivery timestamp with time zone,
    actual_delivery timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: order_splits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.order_splits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    original_order_id uuid NOT NULL,
    new_order_id uuid NOT NULL,
    split_type character varying(30) NOT NULL,
    item_ids jsonb,
    reason text,
    created_by uuid,
    created_at timestamp with time zone
);


--
-- Name: order_timelines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.order_timelines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    event text NOT NULL,
    description text NOT NULL,
    "timestamp" timestamp with time zone NOT NULL,
    created_by text,
    created_at timestamp with time zone
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    order_number text NOT NULL,
    customer_id uuid NOT NULL,
    status character varying(20) DEFAULT 'PLACED'::character varying NOT NULL,
    payment_status character varying(30) DEFAULT 'PENDING'::character varying NOT NULL,
    fulfillment_status character varying(30) DEFAULT 'UNFULFILLED'::character varying NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying NOT NULL,
    subtotal numeric(10,2) NOT NULL,
    tax_amount numeric(10,2) DEFAULT 0,
    shipping_cost numeric(10,2) DEFAULT 0,
    discount_amount numeric(10,2) DEFAULT 0,
    total numeric(10,2) NOT NULL,
    notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    parent_order_id uuid,
    is_split boolean DEFAULT false,
    split_reason character varying(50),
    tax_breakdown jsonb,
    cgst numeric(10,2) DEFAULT 0,
    sgst numeric(10,2) DEFAULT 0,
    igst numeric(10,2) DEFAULT 0,
    utgst numeric(10,2) DEFAULT 0,
    gst_cess numeric(10,2) DEFAULT 0,
    is_interstate boolean DEFAULT false,
    customer_gstin character varying(15),
    vat_amount numeric(10,2) DEFAULT 0,
    is_reverse_charge boolean DEFAULT false,
    customer_vat_number character varying(50),
    storefront_host character varying(255),
    receipt_number character varying(50),
    invoice_number character varying(50),
    receipt_document_id uuid,
    receipt_short_url character varying(255),
    receipt_generated_at timestamp with time zone
);


--
-- Name: receipt_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.receipt_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    order_id uuid NOT NULL,
    vendor_id character varying(255),
    receipt_number character varying(50) NOT NULL,
    invoice_number character varying(50),
    document_type character varying(20) DEFAULT 'RECEIPT'::character varying NOT NULL,
    format character varying(10) DEFAULT 'pdf'::character varying NOT NULL,
    template character varying(50) DEFAULT 'default'::character varying,
    storage_bucket character varying(255),
    storage_path character varying(500),
    document_id character varying(255),
    file_size bigint DEFAULT 0,
    content_checksum character varying(64),
    short_code character varying(20),
    short_url character varying(255),
    expires_at timestamp with time zone,
    access_count bigint DEFAULT 0,
    last_access timestamp with time zone,
    generated_by character varying(255),
    customer_email character varying(255),
    order_total numeric(10,2),
    currency character varying(3) DEFAULT 'USD'::character varying,
    email_sent_at timestamp with time zone,
    email_sent_to character varying(255),
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: receipt_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.receipt_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    default_template character varying(50) DEFAULT 'default'::character varying,
    logo_url character varying(500),
    primary_color character varying(7) DEFAULT '#1a73e8'::character varying,
    secondary_color character varying(7) DEFAULT '#5f6368'::character varying,
    business_name character varying(255),
    business_address text,
    business_phone character varying(50),
    business_email character varying(255),
    business_website character varying(255),
    gstin character varying(15),
    vat_number character varying(50),
    tax_id character varying(50),
    header_text text,
    footer_text text,
    terms_text text,
    show_tax_breakdown boolean DEFAULT true,
    show_hsnsac_codes boolean DEFAULT true,
    show_payment_details boolean DEFAULT true,
    show_shipping_details boolean DEFAULT true,
    include_qr_code boolean DEFAULT true,
    show_item_images boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: return_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.return_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    return_id uuid NOT NULL,
    order_item_id uuid NOT NULL,
    product_id uuid NOT NULL,
    product_name text NOT NULL,
    sku text NOT NULL,
    quantity bigint NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    refund_amount numeric(10,2),
    reason character varying(30),
    item_notes text,
    received_condition character varying(50),
    is_defective boolean DEFAULT false,
    can_resell boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: return_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.return_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    return_window_days bigint DEFAULT 30,
    allow_exchange boolean DEFAULT true,
    allow_store_credit boolean DEFAULT true,
    restocking_fee_percent numeric(5,2) DEFAULT 0,
    free_return_shipping boolean DEFAULT false,
    auto_approve_returns boolean DEFAULT false,
    require_photos boolean DEFAULT false,
    policy_text text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: return_timeline; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.return_timeline (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    return_id uuid NOT NULL,
    status character varying(20) NOT NULL,
    message text NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone
);


--
-- Name: returns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.returns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    rma_number text NOT NULL,
    order_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    reason character varying(30) NOT NULL,
    return_type character varying(20) DEFAULT 'REFUND'::character varying NOT NULL,
    customer_notes text,
    admin_notes text,
    refund_amount numeric(10,2),
    refund_method character varying(30),
    refund_processed_at timestamp with time zone,
    restocking_fee numeric(10,2) DEFAULT 0,
    return_shipping_cost numeric(10,2) DEFAULT 0,
    return_tracking_number text,
    return_carrier text,
    return_shipping_label_url text,
    exchange_order_id uuid,
    exchange_product_id uuid,
    approved_by uuid,
    approved_at timestamp with time zone,
    rejected_by uuid,
    rejected_at timestamp with time zone,
    rejection_reason text,
    inspected_by uuid,
    inspected_at timestamp with time zone,
    inspection_notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: shipping_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.shipping_methods (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    estimated_days_min bigint DEFAULT 1,
    estimated_days_max bigint DEFAULT 5,
    base_rate numeric(10,2) NOT NULL,
    free_shipping_threshold numeric(10,2),
    countries text[],
    is_active boolean DEFAULT true,
    sort_order bigint DEFAULT 0,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: cancellation_settings cancellation_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cancellation_settings
    ADD CONSTRAINT cancellation_settings_pkey PRIMARY KEY (id);


--
-- Name: order_customers order_customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_customers
    ADD CONSTRAINT order_customers_pkey PRIMARY KEY (id);


--
-- Name: order_discounts order_discounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_discounts
    ADD CONSTRAINT order_discounts_pkey PRIMARY KEY (id);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);


--
-- Name: order_payments order_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_payments
    ADD CONSTRAINT order_payments_pkey PRIMARY KEY (id);


--
-- Name: order_refunds order_refunds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_refunds
    ADD CONSTRAINT order_refunds_pkey PRIMARY KEY (id);


--
-- Name: order_shippings order_shippings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_shippings
    ADD CONSTRAINT order_shippings_pkey PRIMARY KEY (id);


--
-- Name: order_splits order_splits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_splits
    ADD CONSTRAINT order_splits_pkey PRIMARY KEY (id);


--
-- Name: order_timelines order_timelines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_timelines
    ADD CONSTRAINT order_timelines_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: receipt_documents receipt_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipt_documents
    ADD CONSTRAINT receipt_documents_pkey PRIMARY KEY (id);


--
-- Name: receipt_settings receipt_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipt_settings
    ADD CONSTRAINT receipt_settings_pkey PRIMARY KEY (id);


--
-- Name: return_items return_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_items
    ADD CONSTRAINT return_items_pkey PRIMARY KEY (id);


--
-- Name: return_policies return_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_policies
    ADD CONSTRAINT return_policies_pkey PRIMARY KEY (id);


--
-- Name: return_timeline return_timeline_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_timeline
    ADD CONSTRAINT return_timeline_pkey PRIMARY KEY (id);


--
-- Name: returns returns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.returns
    ADD CONSTRAINT returns_pkey PRIMARY KEY (id);


--
-- Name: shipping_methods shipping_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipping_methods
    ADD CONSTRAINT shipping_methods_pkey PRIMARY KEY (id);


--
-- Name: order_customers uni_order_customers_order_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_customers
    ADD CONSTRAINT uni_order_customers_order_id UNIQUE (order_id);


--
-- Name: order_payments uni_order_payments_order_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_payments
    ADD CONSTRAINT uni_order_payments_order_id UNIQUE (order_id);


--
-- Name: order_shippings uni_order_shippings_order_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_shippings
    ADD CONSTRAINT uni_order_shippings_order_id UNIQUE (order_id);


--
-- Name: return_policies uni_return_policies_tenant_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_policies
    ADD CONSTRAINT uni_return_policies_tenant_id UNIQUE (tenant_id);


--
-- Name: idx_cancellation_settings_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_cancellation_settings_deleted_at ON public.cancellation_settings USING btree (deleted_at);


--
-- Name: idx_cancellation_settings_tenant_storefront; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_cancellation_settings_tenant_storefront ON public.cancellation_settings USING btree (tenant_id, storefront_id);


--
-- Name: idx_cancellation_settings_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_cancellation_settings_vendor ON public.cancellation_settings USING btree (vendor_id);


--
-- Name: idx_order_items_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_order_items_vendor ON public.order_items USING btree (vendor_id);


--
-- Name: idx_order_refunds_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_order_refunds_order ON public.order_refunds USING btree (order_id);


--
-- Name: idx_order_refunds_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_order_refunds_status ON public.order_refunds USING btree (status);


--
-- Name: idx_order_splits_new_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_order_splits_new_order_id ON public.order_splits USING btree (new_order_id);


--
-- Name: idx_order_splits_original_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_order_splits_original_order_id ON public.order_splits USING btree (original_order_id);


--
-- Name: idx_order_splits_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_order_splits_tenant_id ON public.order_splits USING btree (tenant_id);


--
-- Name: idx_orders_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_deleted_at ON public.orders USING btree (deleted_at);


--
-- Name: idx_orders_invoice_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_invoice_number ON public.orders USING btree (invoice_number);


--
-- Name: idx_orders_parent_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_parent_order_id ON public.orders USING btree (parent_order_id);


--
-- Name: idx_orders_receipt_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_receipt_number ON public.orders USING btree (receipt_number);


--
-- Name: idx_orders_tenant_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_tenant_created ON public.orders USING btree (tenant_id, created_at DESC);


--
-- Name: idx_orders_tenant_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_tenant_customer ON public.orders USING btree (tenant_id, customer_id);


--
-- Name: idx_orders_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_tenant_id ON public.orders USING btree (tenant_id);


--
-- Name: idx_orders_tenant_order_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_tenant_order_number ON public.orders USING btree (tenant_id, order_number);


--
-- Name: idx_orders_tenant_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_tenant_status ON public.orders USING btree (tenant_id, status);


--
-- Name: idx_orders_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_tenant_vendor ON public.orders USING btree (vendor_id);


--
-- Name: idx_orders_vendor_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_vendor_created ON public.orders USING btree (vendor_id);


--
-- Name: idx_orders_vendor_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_orders_vendor_status ON public.orders USING btree (vendor_id);


--
-- Name: idx_receipt_docs_invoice; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_receipt_docs_invoice ON public.receipt_documents USING btree (invoice_number);


--
-- Name: idx_receipt_docs_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_receipt_docs_number ON public.receipt_documents USING btree (receipt_number);


--
-- Name: idx_receipt_docs_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_receipt_docs_order ON public.receipt_documents USING btree (order_id);


--
-- Name: idx_receipt_docs_short_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_receipt_docs_short_code ON public.receipt_documents USING btree (short_code);


--
-- Name: idx_receipt_docs_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_receipt_docs_tenant ON public.receipt_documents USING btree (tenant_id);


--
-- Name: idx_receipt_docs_tenant_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_receipt_docs_tenant_order ON public.receipt_documents USING btree (tenant_id, order_id);


--
-- Name: idx_receipt_docs_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_receipt_docs_vendor ON public.receipt_documents USING btree (vendor_id);


--
-- Name: idx_receipt_documents_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_receipt_documents_deleted_at ON public.receipt_documents USING btree (deleted_at);


--
-- Name: idx_receipt_settings_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_receipt_settings_deleted_at ON public.receipt_settings USING btree (deleted_at);


--
-- Name: idx_receipt_settings_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_receipt_settings_tenant ON public.receipt_settings USING btree (tenant_id);


--
-- Name: idx_return_items_return_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_return_items_return_id ON public.return_items USING btree (return_id);


--
-- Name: idx_return_policies_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_return_policies_deleted_at ON public.return_policies USING btree (deleted_at);


--
-- Name: idx_return_timeline_return_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_return_timeline_return_id ON public.return_timeline USING btree (return_id);


--
-- Name: idx_returns_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_returns_deleted_at ON public.returns USING btree (deleted_at);


--
-- Name: idx_returns_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_returns_order ON public.returns USING btree (order_id);


--
-- Name: idx_returns_tenant_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_returns_tenant_created ON public.returns USING btree (tenant_id, created_at DESC);


--
-- Name: idx_returns_tenant_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_returns_tenant_customer ON public.returns USING btree (tenant_id, customer_id);


--
-- Name: idx_returns_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_returns_tenant_id ON public.returns USING btree (tenant_id);


--
-- Name: idx_returns_tenant_rma; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_returns_tenant_rma ON public.returns USING btree (tenant_id, rma_number);


--
-- Name: idx_returns_tenant_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_returns_tenant_status ON public.returns USING btree (tenant_id, status);


--
-- Name: idx_shipping_methods_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipping_methods_deleted_at ON public.shipping_methods USING btree (deleted_at);


--
-- Name: idx_shipping_methods_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_shipping_methods_tenant_id ON public.shipping_methods USING btree (tenant_id);


--
-- Name: order_customers fk_orders_customer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_customers
    ADD CONSTRAINT fk_orders_customer FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_discounts fk_orders_discounts; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_discounts
    ADD CONSTRAINT fk_orders_discounts FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_items fk_orders_items; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT fk_orders_items FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_payments fk_orders_payment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_payments
    ADD CONSTRAINT fk_orders_payment FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_shippings fk_orders_shipping; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_shippings
    ADD CONSTRAINT fk_orders_shipping FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_timelines fk_orders_timeline; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_timelines
    ADD CONSTRAINT fk_orders_timeline FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: return_items fk_returns_items; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_items
    ADD CONSTRAINT fk_returns_items FOREIGN KEY (return_id) REFERENCES public.returns(id) ON DELETE CASCADE;


--
-- Name: returns fk_returns_order; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.returns
    ADD CONSTRAINT fk_returns_order FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: return_timeline fk_returns_timeline; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_timeline
    ADD CONSTRAINT fk_returns_timeline FOREIGN KEY (return_id) REFERENCES public.returns(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


