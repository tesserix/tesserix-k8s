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
-- Name: alert_thresholds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.alert_thresholds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    warehouse_id uuid,
    product_id uuid,
    variant_id uuid,
    alert_type character varying(50) NOT NULL,
    threshold_quantity bigint DEFAULT 10 NOT NULL,
    priority character varying(20) DEFAULT 'MEDIUM'::character varying NOT NULL,
    is_enabled boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: inventory_alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.inventory_alerts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    warehouse_id uuid,
    product_id uuid NOT NULL,
    variant_id uuid,
    type character varying(50) NOT NULL,
    status character varying(50) DEFAULT 'ACTIVE'::character varying NOT NULL,
    priority character varying(20) DEFAULT 'MEDIUM'::character varying NOT NULL,
    title character varying(255) NOT NULL,
    message text NOT NULL,
    current_qty bigint DEFAULT 0 NOT NULL,
    threshold_qty bigint DEFAULT 0 NOT NULL,
    product_name character varying(255),
    product_sku character varying(100),
    warehouse_name character varying(255),
    acknowledged_by character varying(255),
    acknowledged_at timestamp with time zone,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: inventory_transfer_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.inventory_transfer_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    transfer_id uuid NOT NULL,
    product_id uuid NOT NULL,
    variant_id uuid,
    quantity_requested bigint NOT NULL,
    quantity_shipped bigint DEFAULT 0,
    quantity_received bigint DEFAULT 0,
    notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: inventory_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.inventory_transfers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    transfer_number character varying(50) NOT NULL,
    status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    from_warehouse_id uuid NOT NULL,
    to_warehouse_id uuid NOT NULL,
    requested_by text,
    approved_by text,
    completed_by text,
    requested_at timestamp with time zone,
    approved_at timestamp with time zone,
    shipped_at timestamp with time zone,
    completed_at timestamp with time zone,
    notes text,
    metadata jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: purchase_order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.purchase_order_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    purchase_order_id uuid NOT NULL,
    product_id uuid NOT NULL,
    variant_id uuid,
    quantity_ordered bigint NOT NULL,
    quantity_received bigint DEFAULT 0,
    unit_cost numeric(10,2) NOT NULL,
    subtotal numeric(10,2) NOT NULL,
    notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: purchase_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.purchase_orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    po_number character varying(50) NOT NULL,
    status character varying(20) DEFAULT 'DRAFT'::character varying NOT NULL,
    supplier_id uuid NOT NULL,
    warehouse_id uuid NOT NULL,
    order_date timestamp with time zone,
    expected_date timestamp with time zone,
    received_date timestamp with time zone,
    subtotal numeric(10,2) DEFAULT 0 NOT NULL,
    tax numeric(10,2) DEFAULT 0 NOT NULL,
    shipping numeric(10,2) DEFAULT 0 NOT NULL,
    total numeric(10,2) DEFAULT 0 NOT NULL,
    currency_code character varying(3) DEFAULT 'USD'::character varying NOT NULL,
    notes text,
    payment_terms character varying(255),
    shipping_method character varying(255),
    tracking_number character varying(255),
    requested_by text,
    approved_by text,
    received_by text,
    metadata jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text
);


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.suppliers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    code character varying(50) NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(20) DEFAULT 'ACTIVE'::character varying NOT NULL,
    contact_name character varying(255),
    email character varying(255),
    phone character varying(50),
    website character varying(255),
    address1 character varying(255),
    address2 character varying(255),
    city character varying(100),
    state character varying(100),
    postal_code character varying(20),
    country character varying(100),
    tax_id character varying(50),
    payment_terms character varying(255),
    lead_time_days bigint,
    min_order_value numeric(10,2),
    currency_code character varying(3),
    rating numeric(3,2),
    total_orders bigint DEFAULT 0,
    total_spent numeric(12,2) DEFAULT 0,
    notes text,
    metadata jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text
);


--
-- Name: warehouses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.warehouses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    code character varying(50) NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(20) DEFAULT 'ACTIVE'::character varying NOT NULL,
    address1 character varying(255) NOT NULL,
    address2 character varying(255),
    city character varying(100) NOT NULL,
    state character varying(100) NOT NULL,
    postal_code character varying(20) NOT NULL,
    country character varying(100) DEFAULT 'US'::character varying NOT NULL,
    phone character varying(50),
    email character varying(255),
    manager_name character varying(255),
    is_default boolean DEFAULT false,
    priority bigint DEFAULT 0,
    logo_url text,
    metadata jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text
);


--
-- Name: alert_thresholds alert_thresholds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_thresholds
    ADD CONSTRAINT alert_thresholds_pkey PRIMARY KEY (id);


--
-- Name: inventory_alerts inventory_alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_alerts
    ADD CONSTRAINT inventory_alerts_pkey PRIMARY KEY (id);


--
-- Name: inventory_transfer_items inventory_transfer_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transfer_items
    ADD CONSTRAINT inventory_transfer_items_pkey PRIMARY KEY (id);


--
-- Name: inventory_transfers inventory_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transfers
    ADD CONSTRAINT inventory_transfers_pkey PRIMARY KEY (id);


--
-- Name: purchase_order_items purchase_order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_items
    ADD CONSTRAINT purchase_order_items_pkey PRIMARY KEY (id);


--
-- Name: purchase_orders purchase_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (id);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (id);


--
-- Name: warehouses warehouses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_pkey PRIMARY KEY (id);


--
-- Name: idx_alert_thresholds_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_alert_thresholds_product_id ON public.alert_thresholds USING btree (product_id);


--
-- Name: idx_alert_thresholds_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_alert_thresholds_tenant_id ON public.alert_thresholds USING btree (tenant_id);


--
-- Name: idx_alert_thresholds_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_alert_thresholds_variant_id ON public.alert_thresholds USING btree (variant_id);


--
-- Name: idx_alert_thresholds_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_alert_thresholds_warehouse_id ON public.alert_thresholds USING btree (warehouse_id);


--
-- Name: idx_inventory_alerts_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_alerts_product_id ON public.inventory_alerts USING btree (product_id);


--
-- Name: idx_inventory_alerts_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_alerts_status ON public.inventory_alerts USING btree (status);


--
-- Name: idx_inventory_alerts_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_alerts_tenant_id ON public.inventory_alerts USING btree (tenant_id);


--
-- Name: idx_inventory_alerts_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_alerts_type ON public.inventory_alerts USING btree (type);


--
-- Name: idx_inventory_alerts_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_alerts_variant_id ON public.inventory_alerts USING btree (variant_id);


--
-- Name: idx_inventory_alerts_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_alerts_warehouse_id ON public.inventory_alerts USING btree (warehouse_id);


--
-- Name: idx_inventory_transfer_items_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_transfer_items_product_id ON public.inventory_transfer_items USING btree (product_id);


--
-- Name: idx_inventory_transfer_items_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_transfer_items_tenant_id ON public.inventory_transfer_items USING btree (tenant_id);


--
-- Name: idx_inventory_transfer_items_transfer_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_transfer_items_transfer_id ON public.inventory_transfer_items USING btree (transfer_id);


--
-- Name: idx_inventory_transfer_items_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_transfer_items_variant_id ON public.inventory_transfer_items USING btree (variant_id);


--
-- Name: idx_inventory_transfers_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_transfers_deleted_at ON public.inventory_transfers USING btree (deleted_at);


--
-- Name: idx_inventory_transfers_from_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_transfers_from_warehouse_id ON public.inventory_transfers USING btree (from_warehouse_id);


--
-- Name: idx_inventory_transfers_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_transfers_tenant_id ON public.inventory_transfers USING btree (tenant_id);


--
-- Name: idx_inventory_transfers_to_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_inventory_transfers_to_warehouse_id ON public.inventory_transfers USING btree (to_warehouse_id);


--
-- Name: idx_inventory_transfers_transfer_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_inventory_transfers_transfer_number ON public.inventory_transfers USING btree (transfer_number);


--
-- Name: idx_purchase_order_items_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_purchase_order_items_product_id ON public.purchase_order_items USING btree (product_id);


--
-- Name: idx_purchase_order_items_purchase_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_purchase_order_items_purchase_order_id ON public.purchase_order_items USING btree (purchase_order_id);


--
-- Name: idx_purchase_order_items_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_purchase_order_items_tenant_id ON public.purchase_order_items USING btree (tenant_id);


--
-- Name: idx_purchase_order_items_variant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_purchase_order_items_variant_id ON public.purchase_order_items USING btree (variant_id);


--
-- Name: idx_purchase_orders_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_purchase_orders_deleted_at ON public.purchase_orders USING btree (deleted_at);


--
-- Name: idx_purchase_orders_po_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_purchase_orders_po_number ON public.purchase_orders USING btree (po_number);


--
-- Name: idx_purchase_orders_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_purchase_orders_supplier_id ON public.purchase_orders USING btree (supplier_id);


--
-- Name: idx_purchase_orders_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_purchase_orders_tenant_id ON public.purchase_orders USING btree (tenant_id);


--
-- Name: idx_purchase_orders_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_purchase_orders_tenant_vendor ON public.purchase_orders USING btree (vendor_id);


--
-- Name: idx_purchase_orders_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_purchase_orders_warehouse_id ON public.purchase_orders USING btree (warehouse_id);


--
-- Name: idx_suppliers_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_suppliers_deleted_at ON public.suppliers USING btree (deleted_at);


--
-- Name: idx_suppliers_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_suppliers_tenant_id ON public.suppliers USING btree (tenant_id);


--
-- Name: idx_suppliers_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_suppliers_tenant_vendor ON public.suppliers USING btree (vendor_id);


--
-- Name: idx_tenant_supplier_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_supplier_code ON public.suppliers USING btree (code);


--
-- Name: idx_tenant_warehouse_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_warehouse_code ON public.warehouses USING btree (code);


--
-- Name: idx_warehouses_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_warehouses_deleted_at ON public.warehouses USING btree (deleted_at);


--
-- Name: idx_warehouses_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_warehouses_tenant_id ON public.warehouses USING btree (tenant_id);


--
-- Name: idx_warehouses_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_warehouses_tenant_vendor ON public.warehouses USING btree (vendor_id);


--
-- Name: inventory_transfers fk_inventory_transfers_from_warehouse; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transfers
    ADD CONSTRAINT fk_inventory_transfers_from_warehouse FOREIGN KEY (from_warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: inventory_transfer_items fk_inventory_transfers_items; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transfer_items
    ADD CONSTRAINT fk_inventory_transfers_items FOREIGN KEY (transfer_id) REFERENCES public.inventory_transfers(id);


--
-- Name: inventory_transfers fk_inventory_transfers_to_warehouse; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transfers
    ADD CONSTRAINT fk_inventory_transfers_to_warehouse FOREIGN KEY (to_warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: purchase_order_items fk_purchase_orders_items; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_items
    ADD CONSTRAINT fk_purchase_orders_items FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id);


--
-- Name: purchase_orders fk_purchase_orders_supplier; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT fk_purchase_orders_supplier FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id);


--
-- Name: purchase_orders fk_purchase_orders_warehouse; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT fk_purchase_orders_warehouse FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- PostgreSQL database dump complete
--


