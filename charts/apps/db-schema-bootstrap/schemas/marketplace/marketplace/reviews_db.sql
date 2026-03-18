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
-- Name: review_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.review_reactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    review_id uuid NOT NULL,
    user_id text NOT NULL,
    reaction_type text NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    vendor_id text,
    application_id text NOT NULL,
    target_id text NOT NULL,
    target_type text NOT NULL,
    user_id text NOT NULL,
    user_name text,
    title text,
    content text NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    type text NOT NULL,
    visibility text DEFAULT 'PUBLIC'::text NOT NULL,
    ratings jsonb,
    comments jsonb,
    reactions jsonb,
    media jsonb,
    tags jsonb,
    helpful_count bigint DEFAULT 0,
    report_count bigint DEFAULT 0,
    featured boolean DEFAULT false,
    verified_purchase boolean DEFAULT false,
    language text,
    ip_address text,
    user_agent text,
    spam_score numeric,
    sentiment_score numeric,
    moderation_notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    published_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text,
    metadata jsonb,
    not_helpful_count bigint DEFAULT 0
);


--
-- Name: review_reactions review_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.review_reactions
    ADD CONSTRAINT review_reactions_pkey PRIMARY KEY (id);


--
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (id);


--
-- Name: idx_reaction_review_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_reaction_review_user ON public.review_reactions USING btree (review_id, user_id);


--
-- Name: idx_review_reactions_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_review_reactions_tenant_id ON public.review_reactions USING btree (tenant_id);


--
-- Name: idx_reviews_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reviews_deleted_at ON public.reviews USING btree (deleted_at);


--
-- Name: idx_reviews_target_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reviews_target_id ON public.reviews USING btree (target_id);


--
-- Name: idx_reviews_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reviews_tenant_id ON public.reviews USING btree (tenant_id);


--
-- Name: idx_reviews_tenant_vendor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reviews_tenant_vendor ON public.reviews USING btree (vendor_id);


--
-- Name: idx_reviews_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reviews_user_id ON public.reviews USING btree (user_id);


--
-- Name: idx_reviews_vendor_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reviews_vendor_status ON public.reviews USING btree (vendor_id);


--
-- Name: idx_reviews_vendor_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_reviews_vendor_target ON public.reviews USING btree (vendor_id);


--
-- PostgreSQL database dump complete
--


