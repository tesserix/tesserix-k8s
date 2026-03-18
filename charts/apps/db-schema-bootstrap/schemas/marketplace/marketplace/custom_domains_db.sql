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
-- Name: custom_domains; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.custom_domains (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    domain character varying(255) NOT NULL,
    domain_type character varying(20) DEFAULT 'apex'::character varying,
    target_type character varying(20) DEFAULT 'storefront'::character varying,
    tenant_slug character varying(100),
    verification_method character varying(20) DEFAULT 'txt'::character varying,
    verification_token character varying(100),
    verification_record character varying(255),
    dns_verified boolean DEFAULT false,
    dns_verified_at timestamp with time zone,
    dns_last_checked_at timestamp with time zone,
    dns_check_attempts bigint DEFAULT 0,
    ssl_status character varying(20) DEFAULT 'pending'::character varying,
    ssl_provider character varying(50) DEFAULT 'letsencrypt'::character varying,
    ssl_expires_at timestamp with time zone,
    ssl_cert_secret_name character varying(100),
    ssl_last_error character varying(500),
    routing_status character varying(20) DEFAULT 'pending'::character varying,
    virtual_service_name character varying(100),
    gateway_patched boolean DEFAULT false,
    keycloak_updated boolean DEFAULT false,
    keycloak_updated_at timestamp with time zone,
    status character varying(20) DEFAULT 'pending'::character varying,
    status_message character varying(500),
    activated_at timestamp with time zone,
    redirect_www boolean DEFAULT true,
    force_http_s boolean DEFAULT true,
    primary_domain boolean DEFAULT false,
    include_www boolean DEFAULT true,
    created_by uuid,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    cloudflare_tunnel_configured boolean DEFAULT false,
    cloudflare_dns_configured boolean DEFAULT false,
    cloudflare_zone_id character varying(100),
    tunnel_last_checked_at timestamp with time zone,
    session_id character varying(100),
    ns_delegation_enabled boolean DEFAULT false,
    ns_delegation_verified boolean DEFAULT false,
    ns_delegation_verified_at timestamp with time zone,
    ns_delegation_check_attempts bigint DEFAULT 0,
    ns_delegation_last_checked_at timestamp with time zone,
    cname_delegation_target character varying(255)
);


--
-- Name: domain_activities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.domain_activities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    domain_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    action character varying(50) NOT NULL,
    status character varying(20) NOT NULL,
    message character varying(500),
    duration bigint,
    metadata jsonb,
    created_at timestamp with time zone
);


--
-- Name: domain_health_checks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.domain_health_checks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    domain_id uuid NOT NULL,
    is_healthy boolean,
    response_time bigint,
    status_code bigint,
    error_message character varying(500),
    checked_at timestamp with time zone,
    ssl_valid boolean,
    ssl_expires_in bigint
);


--
-- Name: custom_domains custom_domains_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.custom_domains
    ADD CONSTRAINT custom_domains_pkey PRIMARY KEY (id);


--
-- Name: domain_activities domain_activities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.domain_activities
    ADD CONSTRAINT domain_activities_pkey PRIMARY KEY (id);


--
-- Name: domain_health_checks domain_health_checks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.domain_health_checks
    ADD CONSTRAINT domain_health_checks_pkey PRIMARY KEY (id);


--
-- Name: idx_custom_domains_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_custom_domains_deleted_at ON public.custom_domains USING btree (deleted_at);


--
-- Name: idx_custom_domains_domain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_custom_domains_domain ON public.custom_domains USING btree (domain);


--
-- Name: idx_custom_domains_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_custom_domains_session_id ON public.custom_domains USING btree (session_id);


--
-- Name: idx_custom_domains_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_custom_domains_status ON public.custom_domains USING btree (status);


--
-- Name: idx_custom_domains_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_custom_domains_tenant_id ON public.custom_domains USING btree (tenant_id);


--
-- Name: idx_custom_domains_tenant_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_custom_domains_tenant_slug ON public.custom_domains USING btree (tenant_slug);


--
-- Name: idx_domain_activities_domain_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_domain_activities_domain_id ON public.domain_activities USING btree (domain_id);


--
-- Name: idx_domain_activities_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_domain_activities_tenant_id ON public.domain_activities USING btree (tenant_id);


--
-- Name: idx_domain_health_checks_domain_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_domain_health_checks_domain_id ON public.domain_health_checks USING btree (domain_id);


--
-- PostgreSQL database dump complete
--


