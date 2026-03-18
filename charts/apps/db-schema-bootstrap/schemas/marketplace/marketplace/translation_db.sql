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
-- Name: languages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.languages (
    code character varying(10) NOT NULL,
    name character varying(100) NOT NULL,
    native_name character varying(100),
    rtl boolean DEFAULT false,
    is_active boolean DEFAULT true,
    region character varying(50),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: tenant_language_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.tenant_language_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(50) NOT NULL,
    default_source_lang character varying(10) DEFAULT 'en'::character varying,
    default_target_lang character varying(10) DEFAULT 'hi'::character varying,
    enabled_languages jsonb,
    auto_detect boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: translation_caches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.translation_caches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(50) NOT NULL,
    source_lang character varying(10) NOT NULL,
    target_lang character varying(10) NOT NULL,
    source_hash character varying(64) NOT NULL,
    source_text text NOT NULL,
    translated_text text NOT NULL,
    context character varying(100),
    hit_count bigint DEFAULT 0,
    provider character varying(50),
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    expires_at timestamp with time zone
);


--
-- Name: translation_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.translation_stats (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(50) NOT NULL,
    total_requests bigint DEFAULT 0,
    cache_hits bigint DEFAULT 0,
    cache_misses bigint DEFAULT 0,
    total_characters bigint DEFAULT 0,
    last_request_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: user_language_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.user_language_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(50) NOT NULL,
    user_id uuid NOT NULL,
    preferred_language character varying(10) DEFAULT 'en'::character varying NOT NULL,
    source_language character varying(10) DEFAULT 'en'::character varying,
    auto_detect_source boolean DEFAULT true,
    rtl_enabled boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: languages languages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.languages
    ADD CONSTRAINT languages_pkey PRIMARY KEY (code);


--
-- Name: tenant_language_preferences tenant_language_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_language_preferences
    ADD CONSTRAINT tenant_language_preferences_pkey PRIMARY KEY (id);


--
-- Name: translation_caches translation_caches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_caches
    ADD CONSTRAINT translation_caches_pkey PRIMARY KEY (id);


--
-- Name: translation_stats translation_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translation_stats
    ADD CONSTRAINT translation_stats_pkey PRIMARY KEY (id);


--
-- Name: user_language_preferences user_language_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_language_preferences
    ADD CONSTRAINT user_language_preferences_pkey PRIMARY KEY (id);


--
-- Name: idx_tenant_language_preferences_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_language_preferences_tenant_id ON public.tenant_language_preferences USING btree (tenant_id);


--
-- Name: idx_translation_cache_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_translation_cache_unique ON public.translation_caches USING btree (source_hash);


--
-- Name: idx_translation_caches_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_translation_caches_expires_at ON public.translation_caches USING btree (expires_at);


--
-- Name: idx_translation_caches_source_lang; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_translation_caches_source_lang ON public.translation_caches USING btree (source_lang);


--
-- Name: idx_translation_caches_target_lang; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_translation_caches_target_lang ON public.translation_caches USING btree (target_lang);


--
-- Name: idx_translation_caches_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_translation_caches_tenant_id ON public.translation_caches USING btree (tenant_id);


--
-- Name: idx_translation_stats_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_translation_stats_tenant_id ON public.translation_stats USING btree (tenant_id);


--
-- Name: idx_user_lang_pref_tenant_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_lang_pref_tenant_user ON public.user_language_preferences USING btree (tenant_id, user_id);


--
-- PostgreSQL database dump complete
--


