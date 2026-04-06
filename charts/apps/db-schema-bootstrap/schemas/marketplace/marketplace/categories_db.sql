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
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    created_by_id text NOT NULL,
    updated_by_id text NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    description text,
    image_url text,
    banner_url text,
    images jsonb,
    parent_id uuid,
    level bigint DEFAULT 0 NOT NULL,
    "position" bigint DEFAULT 1 NOT NULL,
    is_active boolean DEFAULT true,
    status text DEFAULT 'DRAFT'::text NOT NULL,
    tier text,
    tags jsonb,
    seo_title text,
    seo_description text,
    seo_keywords jsonb,
    metadata jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: category_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.category_audit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category_id uuid NOT NULL,
    user_id character varying(255) NOT NULL,
    action character varying(50) NOT NULL,
    fields_changed jsonb,
    old_values jsonb,
    new_values jsonb,
    "timestamp" timestamp without time zone DEFAULT now() NOT NULL,
    ip_address character varying(45)
);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: category_audit category_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.category_audit
    ADD CONSTRAINT category_audit_pkey PRIMARY KEY (id);


--
-- Name: idx_categories_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_categories_deleted_at ON public.categories USING btree (deleted_at);


--
-- Name: idx_categories_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_categories_parent_id ON public.categories USING btree (parent_id);


--
-- Name: idx_categories_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_categories_slug ON public.categories USING btree (slug);


--
-- Name: idx_categories_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_categories_status ON public.categories USING btree (status);


--
-- Name: idx_categories_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_categories_tenant_id ON public.categories USING btree (tenant_id);


--
-- Name: idx_category_audit_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_category_audit_category_id ON public.category_audit USING btree (category_id);


--
-- Name: idx_category_audit_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_category_audit_timestamp ON public.category_audit USING btree ("timestamp");


--
-- Name: idx_categories_tenant_slug; Type: INDEX; Schema: public; Owner: -
-- Tenant-scoped slug uniqueness for multi-tenant isolation
--

DROP INDEX IF EXISTS idx_tenant_slug;
CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_tenant_slug ON public.categories USING btree (tenant_id, slug) WHERE (deleted_at IS NULL);


--
-- Name: categories fk_categories_children; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT fk_categories_children FOREIGN KEY (parent_id) REFERENCES public.categories(id);


--
-- PostgreSQL database dump complete
--


