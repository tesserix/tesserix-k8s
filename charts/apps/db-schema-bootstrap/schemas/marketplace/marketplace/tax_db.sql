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
-- Name: migration_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.migration_records (
    id bigint NOT NULL,
    version character varying(255),
    applied_at bigint
);


--
-- Name: migration_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE IF NOT EXISTS public.migration_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: migration_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.migration_records_id_seq OWNED BY public.migration_records.id;


--
-- Name: product_tax_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.product_tax_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    tax_code character varying(50),
    hsn_code character varying(10),
    sac_code character varying(10),
    gst_slab numeric(5,2),
    is_tax_exempt boolean DEFAULT false,
    is_nil_rated boolean DEFAULT false,
    is_zero_rated boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: TABLE product_tax_categories; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.product_tax_categories IS 'Common product categories with tax treatment';


--
-- Name: COLUMN product_tax_categories.hsn_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.product_tax_categories.hsn_code IS 'India HSN code (Harmonized System Nomenclature) for goods - 4 to 8 digits';


--
-- Name: COLUMN product_tax_categories.sac_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.product_tax_categories.sac_code IS 'India SAC code (Services Accounting Code) for services - 6 digits';


--
-- Name: COLUMN product_tax_categories.gst_slab; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.product_tax_categories.gst_slab IS 'India GST slab rate (0, 5, 12, 18, 28). Used when no specific rate is configured.';


--
-- Name: COLUMN product_tax_categories.is_nil_rated; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.product_tax_categories.is_nil_rated IS 'India: 0% GST but seller cannot claim input tax credit';


--
-- Name: COLUMN product_tax_categories.is_zero_rated; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.product_tax_categories.is_zero_rated IS 'EU VAT: 0% rate but seller can claim input tax credit (exports, etc.)';


--
-- Name: tax_calculation_caches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tax_calculation_caches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    cache_key character varying(255) NOT NULL,
    jurisdiction_ids jsonb,
    subtotal numeric(12,2) NOT NULL,
    shipping_amount numeric(12,2),
    tax_amount numeric(12,2) NOT NULL,
    tax_breakdown jsonb,
    calculation_result text,
    created_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: tax_exemption_certificates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tax_exemption_certificates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    customer_id uuid NOT NULL,
    certificate_number character varying(100) NOT NULL,
    certificate_type character varying(50) NOT NULL,
    jurisdiction_id uuid,
    applies_to_all_jurisdictions boolean DEFAULT false,
    issued_date date NOT NULL,
    expiry_date date,
    document_url character varying(500),
    status character varying(50) DEFAULT 'ACTIVE'::character varying,
    verified_at timestamp with time zone,
    verified_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: tax_jurisdictions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tax_jurisdictions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    type character varying(50) NOT NULL,
    code character varying(50) NOT NULL,
    state_code character varying(10),
    parent_id uuid,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: TABLE tax_jurisdictions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tax_jurisdictions IS 'Global tax jurisdictions including India GST states, EU countries, and other major markets';


--
-- Name: COLUMN tax_jurisdictions.state_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tax_jurisdictions.state_code IS 'State code for interstate tax determination (India: MH, KA, etc.)';


--
-- Name: tax_nexus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tax_nexus (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    jurisdiction_id uuid NOT NULL,
    nexus_type character varying(50) NOT NULL,
    registration_number character varying(100),
    effective_date date NOT NULL,
    notes text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    gstin character varying(15),
    is_composition_scheme boolean DEFAULT false,
    vat_number character varying(50)
);


--
-- Name: COLUMN tax_nexus.gstin; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tax_nexus.gstin IS 'India Goods and Services Tax Identification Number (15 characters)';


--
-- Name: COLUMN tax_nexus.is_composition_scheme; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tax_nexus.is_composition_scheme IS 'India: Business opted for GST composition scheme (limited to intrastate B2C)';


--
-- Name: COLUMN tax_nexus.vat_number; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tax_nexus.vat_number IS 'EU VAT registration number';


--
-- Name: tax_rate_category_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tax_rate_category_overrides (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tax_rate_id uuid NOT NULL,
    category_id uuid NOT NULL,
    override_rate numeric(10,6),
    is_exempt boolean DEFAULT false,
    created_at timestamp with time zone
);


--
-- Name: tax_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tax_rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    jurisdiction_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    rate numeric(10,6) NOT NULL,
    tax_type character varying(50) NOT NULL,
    priority bigint DEFAULT 0,
    is_compound boolean DEFAULT false,
    applies_to_shipping boolean DEFAULT false,
    applies_to_products boolean DEFAULT true,
    effective_from timestamp with time zone NOT NULL,
    effective_to timestamp with time zone,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: TABLE tax_rates; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tax_rates IS 'Tax rates for all jurisdictions including India CGST/SGST/IGST slabs, EU VAT, and Canada GST/HST/PST/QST';


--
-- Name: COLUMN tax_rates.is_compound; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tax_rates.is_compound IS 'If true, tax is calculated on subtotal + previous taxes (compound). Used for Quebec QST on GST.';


--
-- Name: tax_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tax_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    report_type character varying(50) NOT NULL,
    jurisdiction_id uuid,
    period_start date NOT NULL,
    period_end date NOT NULL,
    total_sales numeric(12,2) DEFAULT 0,
    taxable_sales numeric(12,2) DEFAULT 0,
    exempt_sales numeric(12,2) DEFAULT 0,
    tax_collected numeric(12,2) DEFAULT 0,
    tax_breakdown jsonb,
    status character varying(50) DEFAULT 'DRAFT'::character varying,
    filed_at timestamp with time zone,
    payment_due_date date,
    paid_at timestamp with time zone,
    report_url character varying(500),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: migration_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.migration_records ALTER COLUMN id SET DEFAULT nextval('public.migration_records_id_seq'::regclass);


--
-- Name: migration_records migration_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.migration_records
    ADD CONSTRAINT migration_records_pkey PRIMARY KEY (id);


--
-- Name: product_tax_categories product_tax_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_tax_categories
    ADD CONSTRAINT product_tax_categories_pkey PRIMARY KEY (id);


--
-- Name: tax_calculation_caches tax_calculation_caches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_calculation_caches
    ADD CONSTRAINT tax_calculation_caches_pkey PRIMARY KEY (id);


--
-- Name: tax_exemption_certificates tax_exemption_certificates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_exemption_certificates
    ADD CONSTRAINT tax_exemption_certificates_pkey PRIMARY KEY (id);


--
-- Name: tax_jurisdictions tax_jurisdictions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_jurisdictions
    ADD CONSTRAINT tax_jurisdictions_pkey PRIMARY KEY (id);


--
-- Name: tax_nexus tax_nexus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_nexus
    ADD CONSTRAINT tax_nexus_pkey PRIMARY KEY (id);


--
-- Name: tax_rate_category_overrides tax_rate_category_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_rate_category_overrides
    ADD CONSTRAINT tax_rate_category_overrides_pkey PRIMARY KEY (id);


--
-- Name: tax_rates tax_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_rates
    ADD CONSTRAINT tax_rates_pkey PRIMARY KEY (id);


--
-- Name: tax_reports tax_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_reports
    ADD CONSTRAINT tax_reports_pkey PRIMARY KEY (id);


--
-- Name: idx_category_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_category_unique ON public.product_tax_categories USING btree (tenant_id, name);


--
-- Name: idx_exemption_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_exemption_unique ON public.tax_exemption_certificates USING btree (tenant_id, customer_id, certificate_number);


--
-- Name: idx_jurisdiction_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_jurisdiction_unique ON public.tax_jurisdictions USING btree (tenant_id, type, code);


--
-- Name: idx_migration_records_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_migration_records_version ON public.migration_records USING btree (version);


--
-- Name: idx_nexus_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_nexus_unique ON public.tax_nexus USING btree (tenant_id, jurisdiction_id);


--
-- Name: idx_product_tax_categories_hsn; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_product_tax_categories_hsn ON public.product_tax_categories USING btree (hsn_code) WHERE (hsn_code IS NOT NULL);


--
-- Name: idx_product_tax_categories_sac; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_product_tax_categories_sac ON public.product_tax_categories USING btree (sac_code) WHERE (sac_code IS NOT NULL);


--
-- Name: idx_tax_calculation_caches_cache_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_tax_calculation_caches_cache_key ON public.tax_calculation_caches USING btree (cache_key);


--
-- Name: idx_tax_calculation_caches_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tax_calculation_caches_expires_at ON public.tax_calculation_caches USING btree (expires_at);


--
-- Name: idx_tax_rates_active_compound; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tax_rates_active_compound ON public.tax_rates USING btree (is_active, is_compound, priority);


--
-- Name: tax_exemption_certificates fk_tax_exemption_certificates_jurisdiction; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_exemption_certificates
    ADD CONSTRAINT fk_tax_exemption_certificates_jurisdiction FOREIGN KEY (jurisdiction_id) REFERENCES public.tax_jurisdictions(id);


--
-- Name: tax_jurisdictions fk_tax_jurisdictions_children; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_jurisdictions
    ADD CONSTRAINT fk_tax_jurisdictions_children FOREIGN KEY (parent_id) REFERENCES public.tax_jurisdictions(id);


--
-- Name: tax_rates fk_tax_jurisdictions_tax_rates; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_rates
    ADD CONSTRAINT fk_tax_jurisdictions_tax_rates FOREIGN KEY (jurisdiction_id) REFERENCES public.tax_jurisdictions(id);


--
-- Name: tax_nexus fk_tax_nexus_jurisdiction; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_nexus
    ADD CONSTRAINT fk_tax_nexus_jurisdiction FOREIGN KEY (jurisdiction_id) REFERENCES public.tax_jurisdictions(id);


--
-- Name: tax_rate_category_overrides fk_tax_rate_category_overrides_category; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_rate_category_overrides
    ADD CONSTRAINT fk_tax_rate_category_overrides_category FOREIGN KEY (category_id) REFERENCES public.product_tax_categories(id);


--
-- Name: tax_rate_category_overrides fk_tax_rate_category_overrides_tax_rate; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_rate_category_overrides
    ADD CONSTRAINT fk_tax_rate_category_overrides_tax_rate FOREIGN KEY (tax_rate_id) REFERENCES public.tax_rates(id);


--
-- Name: tax_reports fk_tax_reports_jurisdiction; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_reports
    ADD CONSTRAINT fk_tax_reports_jurisdiction FOREIGN KEY (jurisdiction_id) REFERENCES public.tax_jurisdictions(id);


--
-- PostgreSQL database dump complete
--


