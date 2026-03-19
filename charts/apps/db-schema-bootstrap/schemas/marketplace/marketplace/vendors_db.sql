--
-- PostgreSQL database dump
--

\restrict 77aPc3k4eI6LJFtVBpblLoRcbyjtjBAaem0HQpVP7GsdCjNurHMG4AbqIZXhUHf

-- Dumped from database version 16.13
-- Dumped by pg_dump version 16.13

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
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: address_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.address_type AS ENUM (
    'BUSINESS',
    'WAREHOUSE',
    'RETURNS'
);


ALTER TYPE public.address_type OWNER TO postgres;

--
-- Name: payment_method; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.payment_method AS ENUM (
    'BANK_TRANSFER',
    'WIRE',
    'CHECK',
    'ACH'
);


ALTER TYPE public.payment_method OWNER TO postgres;

--
-- Name: validation_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.validation_status AS ENUM (
    'NOT_STARTED',
    'IN_PROGRESS',
    'COMPLETED',
    'FAILED',
    'EXPIRED'
);


ALTER TYPE public.validation_status OWNER TO postgres;

--
-- Name: vendor_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.vendor_status AS ENUM (
    'PENDING',
    'ACTIVE',
    'INACTIVE',
    'SUSPENDED',
    'TERMINATED'
);


ALTER TYPE public.vendor_status OWNER TO postgres;

--
-- Name: ensure_single_default_address(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.ensure_single_default_address() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.is_default = true THEN
        UPDATE vendor_addresses 
        SET is_default = false 
        WHERE vendor_id = NEW.vendor_id 
          AND address_type = NEW.address_type 
          AND id != NEW.id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.ensure_single_default_address() OWNER TO postgres;

--
-- Name: ensure_single_default_payment(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.ensure_single_default_payment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.is_default = true THEN
        UPDATE vendor_payments 
        SET is_default = false 
        WHERE vendor_id = NEW.vendor_id 
          AND id != NEW.id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.ensure_single_default_payment() OWNER TO postgres;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_updated_at_column() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: storefronts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.storefronts (
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
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    created_by character varying(255),
    updated_by character varying(255)
);


ALTER TABLE public.storefronts OWNER TO postgres;

--
-- Name: vendor_addresses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.vendor_addresses (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    vendor_id uuid NOT NULL,
    address_type public.address_type NOT NULL,
    address_line1 character varying(255) NOT NULL,
    address_line2 character varying(255),
    city character varying(255) NOT NULL,
    state character varying(255) NOT NULL,
    postal_code character varying(50) NOT NULL,
    country character varying(255) NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id character varying(255)
);


ALTER TABLE public.vendor_addresses OWNER TO postgres;

--
-- Name: COLUMN vendor_addresses.tenant_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.vendor_addresses.tenant_id IS 'Denormalized tenant_id for efficient multi-tenant queries';


--
-- Name: vendor_payments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.vendor_payments (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    vendor_id uuid NOT NULL,
    account_holder_name character varying(255) NOT NULL,
    bank_name character varying(255) NOT NULL,
    account_number character varying(255) NOT NULL,
    routing_number character varying(255),
    swift_code character varying(255),
    tax_identifier character varying(255),
    currency character varying(10) DEFAULT 'USD'::character varying NOT NULL,
    payment_method public.payment_method NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    is_verified boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    tenant_id character varying(255)
);


ALTER TABLE public.vendor_payments OWNER TO postgres;

--
-- Name: COLUMN vendor_payments.tenant_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.vendor_payments.tenant_id IS 'Denormalized tenant_id for efficient multi-tenant queries';


--
-- Name: vendors; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.vendors (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    details text,
    status public.vendor_status DEFAULT 'PENDING'::public.vendor_status NOT NULL,
    location character varying(255),
    primary_contact character varying(255) NOT NULL,
    secondary_contact character varying(255),
    email character varying(255) NOT NULL,
    validation_status public.validation_status DEFAULT 'NOT_STARTED'::public.validation_status NOT NULL,
    commission_rate numeric(5,2) DEFAULT 0.0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    business_registration_number character varying(255),
    tax_identification_number character varying(255),
    website character varying(255),
    business_type character varying(255),
    founded_year integer,
    employee_count integer,
    annual_revenue numeric(15,2),
    contract_start_date timestamp with time zone,
    contract_end_date timestamp with time zone,
    contract_renewal_date timestamp with time zone,
    contract_value numeric(15,2),
    payment_terms character varying(255),
    service_level character varying(255),
    certifications jsonb,
    compliance_documents jsonb,
    insurance_info jsonb,
    performance_rating numeric(3,2),
    last_review_date timestamp with time zone,
    next_review_date timestamp with time zone,
    custom_fields jsonb,
    tags jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    created_by character varying(255),
    updated_by character varying(255),
    is_owner_vendor boolean DEFAULT false
);


ALTER TABLE public.vendors OWNER TO postgres;

--
-- Name: COLUMN vendors.is_owner_vendor; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.vendors.is_owner_vendor IS 'TRUE if this is the tenant own vendor (created during onboarding), FALSE for external marketplace vendors';


--
-- Name: storefronts storefronts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.storefronts
    ADD CONSTRAINT storefronts_pkey PRIMARY KEY (id);


--
-- Name: vendor_addresses vendor_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendor_addresses
    ADD CONSTRAINT vendor_addresses_pkey PRIMARY KEY (id);


--
-- Name: vendor_payments vendor_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendor_payments
    ADD CONSTRAINT vendor_payments_pkey PRIMARY KEY (id);


--
-- Name: vendors vendors_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendors
    ADD CONSTRAINT vendors_pkey PRIMARY KEY (id);


--
-- Name: idx_storefronts_custom_domain; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_storefronts_custom_domain ON public.storefronts USING btree (custom_domain) WHERE (custom_domain IS NOT NULL);


--
-- Name: idx_storefronts_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_storefronts_deleted_at ON public.storefronts USING btree (deleted_at);


--
-- Name: idx_storefronts_slug; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_storefronts_slug ON public.storefronts USING btree (slug);


--
-- Name: idx_storefronts_vendor_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_storefronts_vendor_id ON public.storefronts USING btree (vendor_id);


--
-- Name: idx_vendor_addresses_default; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_vendor_addresses_default ON public.vendor_addresses USING btree (vendor_id, address_type) WHERE (is_default = true);


--
-- Name: idx_vendor_addresses_is_default; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_addresses_is_default ON public.vendor_addresses USING btree (is_default);


--
-- Name: idx_vendor_addresses_tenant; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_addresses_tenant ON public.vendor_addresses USING btree (tenant_id);


--
-- Name: idx_vendor_addresses_tenant_vendor; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_addresses_tenant_vendor ON public.vendor_addresses USING btree (tenant_id, vendor_id);


--
-- Name: idx_vendor_addresses_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_addresses_type ON public.vendor_addresses USING btree (address_type);


--
-- Name: idx_vendor_addresses_vendor_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_addresses_vendor_id ON public.vendor_addresses USING btree (vendor_id);


--
-- Name: idx_vendor_payments_default; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_vendor_payments_default ON public.vendor_payments USING btree (vendor_id) WHERE (is_default = true);


--
-- Name: idx_vendor_payments_is_default; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_payments_is_default ON public.vendor_payments USING btree (is_default);


--
-- Name: idx_vendor_payments_is_verified; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_payments_is_verified ON public.vendor_payments USING btree (is_verified);


--
-- Name: idx_vendor_payments_method; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_payments_method ON public.vendor_payments USING btree (payment_method);


--
-- Name: idx_vendor_payments_tenant; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_payments_tenant ON public.vendor_payments USING btree (tenant_id);


--
-- Name: idx_vendor_payments_tenant_vendor; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_payments_tenant_vendor ON public.vendor_payments USING btree (tenant_id, vendor_id);


--
-- Name: idx_vendor_payments_vendor_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendor_payments_vendor_id ON public.vendor_payments USING btree (vendor_id);


--
-- Name: idx_vendors_business_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_business_type ON public.vendors USING btree (business_type);


--
-- Name: idx_vendors_certifications_gin; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_certifications_gin ON public.vendors USING gin (certifications);


--
-- Name: idx_vendors_compliance_documents_gin; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_compliance_documents_gin ON public.vendors USING gin (compliance_documents);


--
-- Name: idx_vendors_contract_end_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_contract_end_date ON public.vendors USING btree (contract_end_date);


--
-- Name: idx_vendors_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_created_at ON public.vendors USING btree (created_at);


--
-- Name: idx_vendors_custom_fields_gin; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_custom_fields_gin ON public.vendors USING gin (custom_fields);


--
-- Name: idx_vendors_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_deleted_at ON public.vendors USING btree (deleted_at);


--
-- Name: idx_vendors_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_email ON public.vendors USING btree (email);


--
-- Name: idx_vendors_insurance_info_gin; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_insurance_info_gin ON public.vendors USING gin (insurance_info);


--
-- Name: idx_vendors_is_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_is_active ON public.vendors USING btree (is_active);


--
-- Name: idx_vendors_is_owner_vendor; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_is_owner_vendor ON public.vendors USING btree (is_owner_vendor);


--
-- Name: idx_vendors_location; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_location ON public.vendors USING btree (location);


--
-- Name: idx_vendors_performance_rating; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_performance_rating ON public.vendors USING btree (performance_rating);


--
-- Name: idx_vendors_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_status ON public.vendors USING btree (status);


--
-- Name: idx_vendors_tags_gin; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_tags_gin ON public.vendors USING gin (tags);


--
-- Name: idx_vendors_tenant_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_vendors_tenant_email ON public.vendors USING btree (tenant_id, email) WHERE (deleted_at IS NULL);


--
-- Name: INDEX idx_vendors_tenant_email; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON INDEX public.idx_vendors_tenant_email IS 'Ensures email uniqueness per tenant, allowing same email across different tenants';


--
-- Name: idx_vendors_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_tenant_id ON public.vendors USING btree (tenant_id);


--
-- Name: idx_vendors_validation_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vendors_validation_status ON public.vendors USING btree (validation_status);


--
-- Name: vendor_addresses ensure_single_default_address_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER ensure_single_default_address_trigger BEFORE INSERT OR UPDATE ON public.vendor_addresses FOR EACH ROW EXECUTE FUNCTION public.ensure_single_default_address();


--
-- Name: vendor_payments ensure_single_default_payment_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER ensure_single_default_payment_trigger BEFORE INSERT OR UPDATE ON public.vendor_payments FOR EACH ROW EXECUTE FUNCTION public.ensure_single_default_payment();


--
-- Name: vendor_addresses update_vendor_addresses_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_vendor_addresses_updated_at BEFORE UPDATE ON public.vendor_addresses FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: vendor_payments update_vendor_payments_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_vendor_payments_updated_at BEFORE UPDATE ON public.vendor_payments FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: vendors update_vendors_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_vendors_updated_at BEFORE UPDATE ON public.vendors FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: storefronts storefronts_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.storefronts
    ADD CONSTRAINT storefronts_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id);


--
-- Name: vendor_addresses vendor_addresses_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendor_addresses
    ADD CONSTRAINT vendor_addresses_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id) ON DELETE CASCADE;


--
-- Name: vendor_payments vendor_payments_vendor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vendor_payments
    ADD CONSTRAINT vendor_payments_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict 77aPc3k4eI6LJFtVBpblLoRcbyjtjBAaem0HQpVP7GsdCjNurHMG4AbqIZXhUHf

