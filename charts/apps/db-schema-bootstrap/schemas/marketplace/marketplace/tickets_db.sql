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
-- Name: tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tickets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ticket_number text NOT NULL,
    tenant_id text NOT NULL,
    application_id text NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    type text NOT NULL,
    status text DEFAULT 'OPEN'::text NOT NULL,
    priority text DEFAULT 'MEDIUM'::text NOT NULL,
    tags jsonb,
    created_by text NOT NULL,
    created_by_name text,
    created_by_email text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    due_date timestamp with time zone,
    estimated_time bigint,
    actual_time bigint,
    parent_ticket_id text,
    assignees jsonb,
    attachments jsonb,
    comments jsonb,
    sla jsonb,
    history jsonb,
    deleted_at timestamp with time zone,
    updated_by text,
    metadata jsonb,
    resolved_at timestamp with time zone
);


--
-- Name: tickets tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tickets
    ADD CONSTRAINT tickets_pkey PRIMARY KEY (id);


--
-- Name: idx_ticket_number_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_ticket_number_tenant ON public.tickets USING btree (ticket_number, tenant_id);


--
-- Name: idx_tickets_created_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tickets_created_by ON public.tickets USING btree (created_by);


--
-- Name: idx_tickets_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tickets_deleted_at ON public.tickets USING btree (deleted_at);


--
-- Name: idx_tickets_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_tickets_tenant_id ON public.tickets USING btree (tenant_id);


--
-- PostgreSQL database dump complete
--


