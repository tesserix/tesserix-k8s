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
-- Name: storefronts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.storefronts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    vendor_id uuid NOT NULL,
    slug character varying(100) NOT NULL,
    name character varying(255) NOT NULL,
    custom_domain character varying(255),
    is_active boolean DEFAULT false,
    is_default boolean DEFAULT false,
    theme_config jsonb DEFAULT '{}'::jsonb,
    settings jsonb DEFAULT '{}'::jsonb,
    logo_url character varying(500),
    favicon_url character varying(500),
    description text,
    meta_title character varying(100),
    meta_desc character varying(300),
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text
);


--
-- Name: vendor_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.vendor_addresses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    vendor_id uuid NOT NULL,
    address_type text NOT NULL,
    address_line1 text NOT NULL,
    address_line2 text,
    city text NOT NULL,
    state text NOT NULL,
    postal_code text NOT NULL,
    country text NOT NULL,
    is_default boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: vendor_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.vendor_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    vendor_id uuid NOT NULL,
    account_holder_name text NOT NULL,
    bank_name text NOT NULL,
    account_number text NOT NULL,
    routing_number text,
    swift_code text,
    tax_identifier text,
    currency text DEFAULT 'USD'::text NOT NULL,
    payment_method text NOT NULL,
    is_default boolean DEFAULT false,
    is_verified boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: vendors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.vendors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    details text,
    status text DEFAULT 'PENDING'::text NOT NULL,
    location text,
    primary_contact text NOT NULL,
    secondary_contact text,
    email text NOT NULL,
    validation_status text DEFAULT 'NOT_STARTED'::text NOT NULL,
    commission_rate numeric DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true,
    is_owner_vendor boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text,
    business_registration_number text,
    tax_identification_number text,
    website text,
    business_type text,
    founded_year bigint,
    employee_count bigint,
    annual_revenue numeric,
    contract_start_date timestamp with time zone,
    contract_end_date timestamp with time zone,
    contract_renewal_date timestamp with time zone,
    contract_value numeric,
    payment_terms text,
    service_level text,
    certifications jsonb,
    compliance_documents jsonb,
    insurance_info jsonb,
    performance_rating numeric,
    last_review_date timestamp with time zone,
    next_review_date timestamp with time zone,
    custom_fields jsonb,
    tags jsonb,
    notes text
);


--
-- Name: storefronts storefronts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storefronts
    ADD CONSTRAINT storefronts_pkey PRIMARY KEY (id);


--
-- Name: vendor_addresses vendor_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_addresses
    ADD CONSTRAINT vendor_addresses_pkey PRIMARY KEY (id);


--
-- Name: vendor_payments vendor_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_payments
    ADD CONSTRAINT vendor_payments_pkey PRIMARY KEY (id);


--
-- Name: vendors vendors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_pkey PRIMARY KEY (id);


--
-- Name: idx_storefronts_custom_domain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_storefronts_custom_domain ON public.storefronts USING btree (custom_domain);


--
-- Name: idx_storefronts_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_storefronts_deleted_at ON public.storefronts USING btree (deleted_at);


--
-- Name: idx_storefronts_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_storefronts_slug ON public.storefronts USING btree (slug);


--
-- Name: idx_storefronts_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_storefronts_vendor_id ON public.storefronts USING btree (vendor_id);


--
-- Name: idx_tenant_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_email ON public.vendors USING btree (tenant_id, email);


--
-- Name: idx_vendor_addresses_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_vendor_addresses_vendor_id ON public.vendor_addresses USING btree (vendor_id);


--
-- Name: idx_vendor_payments_vendor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_vendor_payments_vendor_id ON public.vendor_payments USING btree (vendor_id);


--
-- Name: idx_vendors_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_vendors_deleted_at ON public.vendors USING btree (deleted_at);


--
-- Name: idx_vendors_is_owner_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_vendors_is_owner_vendor ON public.vendors USING btree (is_owner_vendor);


--
-- Name: idx_vendors_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_vendors_tenant_id ON public.vendors USING btree (tenant_id);


--
-- Name: storefronts fk_storefronts_vendor; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storefronts
    ADD CONSTRAINT fk_storefronts_vendor FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- Name: vendor_addresses fk_vendors_addresses; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_addresses
    ADD CONSTRAINT fk_vendors_addresses FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- Name: vendor_payments fk_vendors_payments; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_payments
    ADD CONSTRAINT fk_vendors_payments FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- PostgreSQL database dump complete
--


