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
-- Name: address_proof_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.address_proof_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    country_code character varying(2) NOT NULL,
    proof_type character varying(100) NOT NULL,
    display_name character varying(200) NOT NULL,
    description text,
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true
);


--
-- Name: business_document_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.business_document_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    country_code character varying(2) NOT NULL,
    document_type character varying(100) NOT NULL,
    display_name character varying(200) NOT NULL,
    description text,
    required boolean DEFAULT false,
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true
);


--
-- Name: company_locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.company_locations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    address text NOT NULL,
    city character varying(100),
    country character varying(100),
    is_primary boolean DEFAULT false,
    active boolean DEFAULT true
);


--
-- Name: contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.contacts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    type character varying(50) NOT NULL,
    label character varying(100) NOT NULL,
    email character varying(255),
    phone character varying(50),
    description text,
    response_time character varying(100),
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true
);


--
-- Name: country_defaults; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.country_defaults (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    country_code character varying(2) NOT NULL,
    country_name character varying(100) NOT NULL,
    default_currency character varying(3) NOT NULL,
    default_timezone character varying(100) NOT NULL,
    default_language character varying(10) DEFAULT 'en'::character varying,
    calling_code character varying(10),
    flag_emoji character varying(10),
    active boolean DEFAULT true
);


--
-- Name: faq_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.faq_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    slug character varying(100) NOT NULL,
    description text,
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true
);


--
-- Name: faqs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.faqs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category_id uuid,
    question text NOT NULL,
    answer text NOT NULL,
    sort_order integer DEFAULT 0,
    page_context character varying(50),
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.features (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title character varying(200) NOT NULL,
    description text NOT NULL,
    icon_name character varying(50),
    category character varying(100),
    page_context character varying(50),
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: guide_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.guide_steps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    guide_id uuid NOT NULL,
    title character varying(200) NOT NULL,
    description text,
    content text,
    duration character varying(50),
    sort_order integer DEFAULT 0
);


--
-- Name: guides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.guides (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title character varying(200) NOT NULL,
    slug character varying(200) NOT NULL,
    description text,
    icon_name character varying(50),
    duration character varying(50),
    featured boolean DEFAULT false,
    content text,
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true,
    published_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: integration_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.integration_features (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    integration_id uuid NOT NULL,
    feature text NOT NULL,
    sort_order integer DEFAULT 0
);


--
-- Name: integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.integrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    category character varying(50) NOT NULL,
    description text,
    logo_url character varying(500),
    status character varying(20) DEFAULT 'active'::character varying,
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true
);


--
-- Name: payment_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.payment_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    slug character varying(100) NOT NULL,
    price numeric(10,2) NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying NOT NULL,
    billing_cycle character varying(20) NOT NULL,
    trial_days integer DEFAULT 0,
    description text,
    tagline character varying(255),
    featured boolean DEFAULT false,
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: plan_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.plan_features (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_id uuid NOT NULL,
    feature text NOT NULL,
    sort_order integer DEFAULT 0,
    highlighted boolean DEFAULT false
);


--
-- Name: presentation_slides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.presentation_slides (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slide_number integer NOT NULL,
    type character varying(50) NOT NULL,
    label character varying(100),
    title character varying(200),
    title_gradient character varying(200),
    title_highlight character varying(200),
    subtitle text,
    content jsonb,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: regional_pricing; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.regional_pricing (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_id uuid NOT NULL,
    country_code character varying(2) NOT NULL,
    price numeric(10,2) NOT NULL,
    currency character varying(3) NOT NULL
);


--
-- Name: reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    platform_name character varying(100),
    reviewer_name character varying(100) NOT NULL,
    reviewer_company character varying(100),
    content text NOT NULL,
    rating numeric(2,1) NOT NULL,
    review_date date,
    source_url character varying(500),
    verified boolean DEFAULT false,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: social_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.social_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    platform character varying(50) NOT NULL,
    url character varying(500) NOT NULL,
    icon_name character varying(50),
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true
);


--
-- Name: testimonials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.testimonials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    quote text NOT NULL,
    name character varying(100) NOT NULL,
    role character varying(100),
    company character varying(100),
    avatar_url character varying(500),
    initials character varying(5),
    rating integer DEFAULT 5,
    featured boolean DEFAULT false,
    page_context character varying(50),
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    tenant_id uuid,
    status character varying(20) DEFAULT 'approved'::character varying,
    submitted_at timestamp without time zone,
    reviewed_at timestamp without time zone,
    reviewed_by character varying(100),
    revision_notes text
);


--
-- Name: trust_badges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.trust_badges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    label character varying(100) NOT NULL,
    icon_name character varying(50),
    description text,
    page_context character varying(50),
    sort_order integer DEFAULT 0,
    active boolean DEFAULT true
);


--
-- Name: address_proof_types address_proof_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.address_proof_types
    ADD CONSTRAINT address_proof_types_pkey PRIMARY KEY (id);


--
-- Name: business_document_types business_document_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_document_types
    ADD CONSTRAINT business_document_types_pkey PRIMARY KEY (id);


--
-- Name: company_locations company_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_locations
    ADD CONSTRAINT company_locations_pkey PRIMARY KEY (id);


--
-- Name: contacts contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_pkey PRIMARY KEY (id);


--
-- Name: country_defaults country_defaults_country_code_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.country_defaults
    ADD CONSTRAINT country_defaults_country_code_unique UNIQUE (country_code);


--
-- Name: country_defaults country_defaults_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.country_defaults
    ADD CONSTRAINT country_defaults_pkey PRIMARY KEY (id);


--
-- Name: faq_categories faq_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faq_categories
    ADD CONSTRAINT faq_categories_pkey PRIMARY KEY (id);


--
-- Name: faq_categories faq_categories_slug_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faq_categories
    ADD CONSTRAINT faq_categories_slug_unique UNIQUE (slug);


--
-- Name: faqs faqs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faqs
    ADD CONSTRAINT faqs_pkey PRIMARY KEY (id);


--
-- Name: features features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.features
    ADD CONSTRAINT features_pkey PRIMARY KEY (id);


--
-- Name: guide_steps guide_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guide_steps
    ADD CONSTRAINT guide_steps_pkey PRIMARY KEY (id);


--
-- Name: guides guides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guides
    ADD CONSTRAINT guides_pkey PRIMARY KEY (id);


--
-- Name: guides guides_slug_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guides
    ADD CONSTRAINT guides_slug_unique UNIQUE (slug);


--
-- Name: integration_features integration_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_features
    ADD CONSTRAINT integration_features_pkey PRIMARY KEY (id);


--
-- Name: integrations integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integrations
    ADD CONSTRAINT integrations_pkey PRIMARY KEY (id);


--
-- Name: payment_plans payment_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_plans
    ADD CONSTRAINT payment_plans_pkey PRIMARY KEY (id);


--
-- Name: payment_plans payment_plans_slug_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_plans
    ADD CONSTRAINT payment_plans_slug_unique UNIQUE (slug);


--
-- Name: plan_features plan_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_features
    ADD CONSTRAINT plan_features_pkey PRIMARY KEY (id);


--
-- Name: presentation_slides presentation_slides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.presentation_slides
    ADD CONSTRAINT presentation_slides_pkey PRIMARY KEY (id);


--
-- Name: regional_pricing regional_pricing_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regional_pricing
    ADD CONSTRAINT regional_pricing_pkey PRIMARY KEY (id);


--
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (id);


--
-- Name: social_links social_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.social_links
    ADD CONSTRAINT social_links_pkey PRIMARY KEY (id);


--
-- Name: testimonials testimonials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.testimonials
    ADD CONSTRAINT testimonials_pkey PRIMARY KEY (id);


--
-- Name: trust_badges trust_badges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trust_badges
    ADD CONSTRAINT trust_badges_pkey PRIMARY KEY (id);


--
-- Name: address_proof_types_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS address_proof_types_active_idx ON public.address_proof_types USING btree (active);


--
-- Name: address_proof_types_country_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS address_proof_types_country_idx ON public.address_proof_types USING btree (country_code);


--
-- Name: business_document_types_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS business_document_types_active_idx ON public.business_document_types USING btree (active);


--
-- Name: business_document_types_country_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS business_document_types_country_idx ON public.business_document_types USING btree (country_code);


--
-- Name: company_locations_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS company_locations_active_idx ON public.company_locations USING btree (active);


--
-- Name: contacts_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS contacts_active_idx ON public.contacts USING btree (active);


--
-- Name: contacts_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS contacts_type_idx ON public.contacts USING btree (type);


--
-- Name: country_defaults_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS country_defaults_active_idx ON public.country_defaults USING btree (active);


--
-- Name: country_defaults_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS country_defaults_code_idx ON public.country_defaults USING btree (country_code);


--
-- Name: faq_categories_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS faq_categories_active_idx ON public.faq_categories USING btree (active);


--
-- Name: faq_categories_slug_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS faq_categories_slug_idx ON public.faq_categories USING btree (slug);


--
-- Name: faqs_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS faqs_active_idx ON public.faqs USING btree (active);


--
-- Name: faqs_category_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS faqs_category_id_idx ON public.faqs USING btree (category_id);


--
-- Name: faqs_page_context_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS faqs_page_context_idx ON public.faqs USING btree (page_context);


--
-- Name: features_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS features_active_idx ON public.features USING btree (active);


--
-- Name: features_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS features_category_idx ON public.features USING btree (category);


--
-- Name: features_page_context_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS features_page_context_idx ON public.features USING btree (page_context);


--
-- Name: guide_steps_guide_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS guide_steps_guide_id_idx ON public.guide_steps USING btree (guide_id);


--
-- Name: guides_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS guides_active_idx ON public.guides USING btree (active);


--
-- Name: guides_featured_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS guides_featured_idx ON public.guides USING btree (featured);


--
-- Name: guides_slug_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS guides_slug_idx ON public.guides USING btree (slug);


--
-- Name: integration_features_integration_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS integration_features_integration_id_idx ON public.integration_features USING btree (integration_id);


--
-- Name: integrations_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS integrations_active_idx ON public.integrations USING btree (active);


--
-- Name: integrations_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS integrations_category_idx ON public.integrations USING btree (category);


--
-- Name: integrations_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS integrations_status_idx ON public.integrations USING btree (status);


--
-- Name: payment_plans_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS payment_plans_active_idx ON public.payment_plans USING btree (active);


--
-- Name: payment_plans_slug_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS payment_plans_slug_idx ON public.payment_plans USING btree (slug);


--
-- Name: plan_features_plan_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS plan_features_plan_id_idx ON public.plan_features USING btree (plan_id);


--
-- Name: presentation_slides_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS presentation_slides_active_idx ON public.presentation_slides USING btree (active);


--
-- Name: presentation_slides_number_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS presentation_slides_number_idx ON public.presentation_slides USING btree (slide_number);


--
-- Name: presentation_slides_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS presentation_slides_type_idx ON public.presentation_slides USING btree (type);


--
-- Name: regional_pricing_country_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS regional_pricing_country_idx ON public.regional_pricing USING btree (country_code);


--
-- Name: regional_pricing_plan_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS regional_pricing_plan_id_idx ON public.regional_pricing USING btree (plan_id);


--
-- Name: reviews_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS reviews_active_idx ON public.reviews USING btree (active);


--
-- Name: reviews_platform_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS reviews_platform_idx ON public.reviews USING btree (platform_name);


--
-- Name: social_links_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS social_links_active_idx ON public.social_links USING btree (active);


--
-- Name: social_links_platform_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS social_links_platform_idx ON public.social_links USING btree (platform);


--
-- Name: testimonials_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS testimonials_active_idx ON public.testimonials USING btree (active);


--
-- Name: testimonials_featured_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS testimonials_featured_idx ON public.testimonials USING btree (featured);


--
-- Name: testimonials_page_context_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS testimonials_page_context_idx ON public.testimonials USING btree (page_context);


--
-- Name: testimonials_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS testimonials_status_idx ON public.testimonials USING btree (status);


--
-- Name: testimonials_tenant_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS testimonials_tenant_id_idx ON public.testimonials USING btree (tenant_id);


--
-- Name: trust_badges_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS trust_badges_active_idx ON public.trust_badges USING btree (active);


--
-- Name: trust_badges_page_context_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS trust_badges_page_context_idx ON public.trust_badges USING btree (page_context);


--
-- Name: faqs faqs_category_id_faq_categories_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.faqs
    ADD CONSTRAINT faqs_category_id_faq_categories_id_fk FOREIGN KEY (category_id) REFERENCES public.faq_categories(id) ON DELETE SET NULL;


--
-- Name: guide_steps guide_steps_guide_id_guides_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guide_steps
    ADD CONSTRAINT guide_steps_guide_id_guides_id_fk FOREIGN KEY (guide_id) REFERENCES public.guides(id) ON DELETE CASCADE;


--
-- Name: integration_features integration_features_integration_id_integrations_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_features
    ADD CONSTRAINT integration_features_integration_id_integrations_id_fk FOREIGN KEY (integration_id) REFERENCES public.integrations(id) ON DELETE CASCADE;


--
-- Name: plan_features plan_features_plan_id_payment_plans_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plan_features
    ADD CONSTRAINT plan_features_plan_id_payment_plans_id_fk FOREIGN KEY (plan_id) REFERENCES public.payment_plans(id) ON DELETE CASCADE;


--
-- Name: regional_pricing regional_pricing_plan_id_payment_plans_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regional_pricing
    ADD CONSTRAINT regional_pricing_plan_id_payment_plans_id_fk FOREIGN KEY (plan_id) REFERENCES public.payment_plans(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


