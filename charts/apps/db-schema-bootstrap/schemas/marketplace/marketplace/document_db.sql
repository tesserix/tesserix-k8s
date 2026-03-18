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
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    filename text NOT NULL,
    original_name text NOT NULL,
    mime_type text NOT NULL,
    size bigint NOT NULL,
    path text NOT NULL,
    bucket text NOT NULL,
    provider text NOT NULL,
    checksum text,
    tags jsonb,
    is_public boolean DEFAULT false,
    url text,
    content_encoding text,
    cache_control text,
    entity_type text,
    entity_id text,
    media_type text,
    "position" bigint DEFAULT 0,
    tenant_id text,
    user_id text,
    product_id text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: idx_documents_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_documents_deleted_at ON public.documents USING btree (deleted_at);


--
-- Name: idx_documents_entity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_documents_entity ON public.documents USING btree (entity_type, entity_id);


--
-- Name: idx_documents_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_documents_product_id ON public.documents USING btree (product_id);


--
-- Name: idx_documents_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_documents_tenant_id ON public.documents USING btree (tenant_id);


--
-- Name: idx_documents_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_documents_user_id ON public.documents USING btree (user_id);


--
-- Name: uni_documents_path; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS uni_documents_path ON public.documents USING btree (path) WHERE (deleted_at IS NULL);


--
-- PostgreSQL database dump complete
--


