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
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    user_id uuid,
    username character varying(255),
    user_email character varying(255),
    action character varying(50) NOT NULL,
    resource character varying(50) NOT NULL,
    resource_id character varying(255),
    resource_name character varying(255),
    status character varying(20) NOT NULL,
    severity character varying(20) DEFAULT 'MEDIUM'::character varying,
    method character varying(10),
    path character varying(500),
    query text,
    ip_address character varying(45),
    user_agent text,
    request_id character varying(100),
    old_value jsonb,
    new_value jsonb,
    changes jsonb,
    description text,
    metadata jsonb,
    tags jsonb,
    error_message text,
    error_code character varying(50),
    service_name character varying(100),
    service_version character varying(50),
    "timestamp" timestamp with time zone NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: audit_retention_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.audit_retention_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    retention_days bigint DEFAULT 180 NOT NULL,
    last_cleanup_at timestamp with time zone,
    logs_deleted bigint,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: audit_retention_settings audit_retention_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_retention_settings
    ADD CONSTRAINT audit_retention_settings_pkey PRIMARY KEY (id);


--
-- Name: idx_audit_logs_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_action ON public.audit_logs USING btree (action);


--
-- Name: idx_audit_logs_ip_address; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_ip_address ON public.audit_logs USING btree (ip_address);


--
-- Name: idx_audit_logs_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_request_id ON public.audit_logs USING btree (request_id);


--
-- Name: idx_audit_logs_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_resource ON public.audit_logs USING btree (resource);


--
-- Name: idx_audit_logs_resource_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_resource_id ON public.audit_logs USING btree (resource_id);


--
-- Name: idx_audit_logs_service_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_service_name ON public.audit_logs USING btree (service_name);


--
-- Name: idx_audit_logs_severity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_severity ON public.audit_logs USING btree (severity);


--
-- Name: idx_audit_logs_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_status ON public.audit_logs USING btree (status);


--
-- Name: idx_audit_logs_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_tenant_id ON public.audit_logs USING btree (tenant_id);


--
-- Name: idx_audit_logs_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_timestamp ON public.audit_logs USING btree ("timestamp");


--
-- Name: idx_audit_logs_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON public.audit_logs USING btree (user_id);


--
-- Name: idx_audit_retention_settings_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_audit_retention_settings_tenant_id ON public.audit_retention_settings USING btree (tenant_id);


--
-- PostgreSQL database dump complete
--


