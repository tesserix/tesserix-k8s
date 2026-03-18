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
-- Name: exchange_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.exchange_rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    base_currency character varying(3) NOT NULL,
    target_currency character varying(3) NOT NULL,
    rate numeric(20,10) NOT NULL,
    fetched_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    application_id uuid NOT NULL,
    user_id uuid,
    scope character varying(50) NOT NULL,
    branding jsonb,
    theme jsonb,
    layout jsonb,
    animations jsonb,
    localization jsonb,
    ecommerce jsonb,
    security jsonb,
    notifications jsonb,
    marketing jsonb,
    integrations jsonb,
    performance jsonb,
    compliance jsonb,
    features jsonb,
    user_preferences jsonb,
    application jsonb,
    version bigint DEFAULT 1,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: settings_histories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.settings_histories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    settings_id uuid NOT NULL,
    operation character varying(50) NOT NULL,
    changes jsonb,
    user_id uuid,
    reason text,
    created_at timestamp with time zone
);


--
-- Name: settings_presets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.settings_presets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    category character varying(50) NOT NULL,
    settings jsonb NOT NULL,
    preview character varying(500),
    tags jsonb,
    is_default boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: settings_validations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.settings_validations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    field character varying(255) NOT NULL,
    rule character varying(100) NOT NULL,
    message text NOT NULL,
    severity character varying(20) NOT NULL,
    created_at timestamp with time zone
);


--
-- Name: storefront_theme_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.storefront_theme_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    theme_settings_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    version bigint NOT NULL,
    snapshot jsonb NOT NULL,
    change_summary text,
    created_by uuid,
    created_at timestamp with time zone
);


--
-- Name: storefront_theme_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.storefront_theme_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    storefront_id uuid NOT NULL,
    theme_template character varying(50) DEFAULT 'vibrant'::character varying NOT NULL,
    primary_color character varying(20) DEFAULT '#8B5CF6'::character varying NOT NULL,
    secondary_color character varying(20) DEFAULT '#EC4899'::character varying NOT NULL,
    accent_color character varying(20),
    logo_url text,
    favicon_url text,
    font_primary character varying(100) DEFAULT 'Inter'::character varying,
    font_secondary character varying(100) DEFAULT 'system-ui'::character varying,
    color_mode character varying(20) DEFAULT 'both'::character varying,
    header_config jsonb DEFAULT '{}'::jsonb,
    homepage_config jsonb DEFAULT '{}'::jsonb,
    footer_config jsonb DEFAULT '{}'::jsonb,
    product_config jsonb DEFAULT '{}'::jsonb,
    checkout_config jsonb DEFAULT '{}'::jsonb,
    custom_css text,
    typography_config jsonb DEFAULT '{}'::jsonb,
    layout_config jsonb DEFAULT '{}'::jsonb,
    spacing_style_config jsonb DEFAULT '{}'::jsonb,
    mobile_config jsonb DEFAULT '{}'::jsonb,
    advanced_config jsonb DEFAULT '{}'::jsonb,
    content_pages jsonb DEFAULT '[]'::jsonb,
    version bigint DEFAULT 1,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_by uuid,
    updated_by uuid
);


--
-- Name: exchange_rates exchange_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT exchange_rates_pkey PRIMARY KEY (id);


--
-- Name: settings_histories settings_histories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings_histories
    ADD CONSTRAINT settings_histories_pkey PRIMARY KEY (id);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (id);


--
-- Name: settings_presets settings_presets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings_presets
    ADD CONSTRAINT settings_presets_pkey PRIMARY KEY (id);


--
-- Name: settings_validations settings_validations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings_validations
    ADD CONSTRAINT settings_validations_pkey PRIMARY KEY (id);


--
-- Name: storefront_theme_history storefront_theme_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storefront_theme_history
    ADD CONSTRAINT storefront_theme_history_pkey PRIMARY KEY (id);


--
-- Name: storefront_theme_settings storefront_theme_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storefront_theme_settings
    ADD CONSTRAINT storefront_theme_settings_pkey PRIMARY KEY (id);


--
-- Name: idx_exchange_rates_currencies; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_exchange_rates_currencies ON public.exchange_rates USING btree (base_currency, target_currency);


--
-- Name: idx_exchange_rates_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_exchange_rates_deleted_at ON public.exchange_rates USING btree (deleted_at);


--
-- Name: idx_settings_application_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_settings_application_id ON public.settings USING btree (application_id);


--
-- Name: idx_settings_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_settings_deleted_at ON public.settings USING btree (deleted_at);


--
-- Name: idx_settings_histories_settings_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_settings_histories_settings_id ON public.settings_histories USING btree (settings_id);


--
-- Name: idx_settings_presets_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_settings_presets_deleted_at ON public.settings_presets USING btree (deleted_at);


--
-- Name: idx_settings_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_settings_scope ON public.settings USING btree (scope);


--
-- Name: idx_settings_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_settings_tenant_id ON public.settings USING btree (tenant_id);


--
-- Name: idx_settings_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_settings_user_id ON public.settings USING btree (user_id);


--
-- Name: idx_storefront_theme_history_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_storefront_theme_history_tenant_id ON public.storefront_theme_history USING btree (tenant_id);


--
-- Name: idx_storefront_theme_history_theme_settings_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_storefront_theme_history_theme_settings_id ON public.storefront_theme_history USING btree (theme_settings_id);


--
-- Name: idx_storefront_theme_settings_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_storefront_theme_settings_deleted_at ON public.storefront_theme_settings USING btree (deleted_at);


--
-- Name: idx_storefront_theme_settings_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_storefront_theme_settings_tenant_id ON public.storefront_theme_settings USING btree (tenant_id);


--
-- Name: idx_storefront_theme_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_storefront_theme_unique ON public.storefront_theme_settings USING btree (storefront_id);


--
-- PostgreSQL database dump complete
--


