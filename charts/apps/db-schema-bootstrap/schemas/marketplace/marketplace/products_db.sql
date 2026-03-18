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
-- Name: product_variants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.product_variants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    sku text NOT NULL,
    name text NOT NULL,
    price text NOT NULL,
    compare_price text,
    cost_price text,
    quantity bigint DEFAULT 0 NOT NULL,
    low_stock_threshold bigint,
    weight text,
    dimensions jsonb,
    inventory_status text,
    sync_status text,
    version bigint DEFAULT 1,
    offline_id text,
    images jsonb,
    attributes jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp without time zone
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    vendor_id text NOT NULL,
    category_id text NOT NULL,
    created_by_id text,
    name text NOT NULL,
    slug text,
    sku text NOT NULL,
    brand text,
    description text,
    price text NOT NULL,
    compare_price text,
    cost_price text,
    status text DEFAULT 'DRAFT'::character varying NOT NULL,
    inventory_status text,
    quantity bigint,
    min_order_qty bigint,
    max_order_qty bigint,
    low_stock_threshold bigint,
    weight text,
    dimensions jsonb,
    search_keywords text,
    search_vector tsvector,
    average_rating numeric(3,2),
    review_count bigint DEFAULT 0,
    tags jsonb,
    currency_code text,
    sync_status text,
    synced_at timestamp without time zone,
    version bigint DEFAULT 1,
    offline_id text,
    localizations jsonb,
    attributes jsonb,
    images jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp without time zone,
    created_by text,
    updated_by text,
    metadata jsonb,
    warehouse_id text,
    supplier_id text,
    logo_url text,
    banner_url text,
    videos jsonb,
    warehouse_name text,
    supplier_name text
);


--
-- Name: search_analytics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.search_analytics (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    query text NOT NULL,
    results_count integer,
    filters jsonb,
    user_id uuid,
    session_id character varying(255),
    ip_address character varying(45),
    user_agent text,
    clicked_result uuid,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: product_variants product_variants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_variants
    ADD CONSTRAINT product_variants_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: search_analytics search_analytics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_analytics
    ADD CONSTRAINT search_analytics_pkey PRIMARY KEY (id);


--
-- Name: product_variants uni_product_variants_sku; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_variants
    ADD CONSTRAINT uni_product_variants_sku UNIQUE (sku);


--
-- Name: idx_product_variants_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_product_variants_deleted_at ON public.product_variants USING btree (deleted_at);


--
-- Name: idx_product_variants_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_product_variants_product_id ON public.product_variants USING btree (product_id);


--
-- Name: idx_product_variants_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_product_variants_sku ON public.product_variants USING btree (sku) WHERE (deleted_at IS NULL);


--
-- Name: idx_products_brand; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_brand ON public.products USING btree (brand);


--
-- Name: idx_products_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_category_id ON public.products USING btree (category_id);


--
-- Name: idx_products_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_deleted_at ON public.products USING btree (deleted_at);


--
-- Name: idx_products_search_vector; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_search_vector ON public.products USING gin (search_vector);


--
-- Name: idx_products_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_products_sku ON public.products USING btree (sku) WHERE (deleted_at IS NULL);


--
-- Name: idx_products_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_status ON public.products USING btree (status);


--
-- Name: idx_products_supplier_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_supplier_id ON public.products USING btree (supplier_id);


--
-- Name: idx_products_supplier_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_supplier_name ON public.products USING btree (supplier_name);


--
-- Name: idx_products_tenant_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_tenant_category ON public.products USING btree (tenant_id, category_id);


--
-- Name: idx_products_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_tenant_id ON public.products USING btree (tenant_id);


--
-- Name: idx_products_tenant_inventory; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_tenant_inventory ON public.products USING btree (tenant_id, inventory_status);


--
-- Name: idx_products_tenant_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_products_tenant_sku ON public.products USING btree (tenant_id, sku);


--
-- Name: idx_products_tenant_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_products_tenant_slug ON public.products USING btree (tenant_id, slug) WHERE (deleted_at IS NULL);


--
-- Name: idx_products_tenant_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_tenant_status ON public.products USING btree (tenant_id, status);


--
-- Name: idx_products_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_tenant_vendor ON public.products USING btree (tenant_id, vendor_id);


--
-- Name: idx_products_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_vendor_id ON public.products USING btree (vendor_id);


--
-- Name: idx_products_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_warehouse_id ON public.products USING btree (warehouse_id);


--
-- Name: idx_products_warehouse_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_products_warehouse_name ON public.products USING btree (warehouse_name);


--
-- Name: idx_search_analytics_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_search_analytics_created_at ON public.search_analytics USING btree (created_at);


--
-- Name: idx_search_analytics_query; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_search_analytics_query ON public.search_analytics USING btree (query);


--
-- Name: idx_search_analytics_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_search_analytics_tenant_id ON public.search_analytics USING btree (tenant_id);


--
-- Name: product_variants fk_products_variants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_variants
    ADD CONSTRAINT fk_products_variants FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: product_variants product_variants_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_variants
    ADD CONSTRAINT product_variants_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


