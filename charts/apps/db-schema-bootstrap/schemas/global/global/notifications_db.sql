--
-- PostgreSQL database dump
--

\restrict qVNofrsu9uknJ0XIhU64tF4QBIKhzWESbTdda65vv3CvqZ74hNI0I9ledzkp1d3

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

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: notification_batches; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    description text,
    template_id uuid,
    channel text NOT NULL,
    total_count bigint DEFAULT 0,
    sent_count bigint DEFAULT 0,
    failed_count bigint DEFAULT 0,
    status text DEFAULT 'pending'::text NOT NULL,
    scheduled_for timestamp with time zone,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


ALTER TABLE public.notification_batches OWNER TO postgres;

--
-- Name: notification_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    notification_id uuid NOT NULL,
    event text NOT NULL,
    status text NOT NULL,
    message text,
    data jsonb,
    created_at timestamp with time zone
);


ALTER TABLE public.notification_logs OWNER TO postgres;

--
-- Name: notification_preferences; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    user_id uuid NOT NULL,
    email_enabled boolean DEFAULT true,
    sms_enabled boolean DEFAULT true,
    push_enabled boolean DEFAULT true,
    marketing_enabled boolean DEFAULT true,
    orders_enabled boolean DEFAULT true,
    security_enabled boolean DEFAULT true,
    email text,
    phone text,
    push_tokens jsonb,
    push_subscriptions jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    websocket_enabled boolean DEFAULT true,
    sse_enabled boolean DEFAULT true,
    category_preferences jsonb DEFAULT '{}'::jsonb,
    sound_enabled boolean DEFAULT true,
    vibration_enabled boolean DEFAULT true,
    quiet_hours_enabled boolean DEFAULT false,
    quiet_hours_start timestamp with time zone,
    quiet_hours_end timestamp with time zone,
    quiet_hours_timezone character varying(50),
    group_similar boolean DEFAULT true
);


ALTER TABLE public.notification_preferences OWNER TO postgres;

--
-- Name: notification_templates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notification_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    name text NOT NULL,
    description text,
    slug text NOT NULL,
    channel text NOT NULL,
    category text,
    subject text,
    body_template text,
    html_template text,
    variables jsonb,
    default_data jsonb,
    version bigint DEFAULT 1,
    is_active boolean DEFAULT true,
    is_system boolean DEFAULT false,
    tags jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


ALTER TABLE public.notification_templates OWNER TO postgres;

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    channel text DEFAULT 'in_app'::character varying NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    priority text DEFAULT 'normal'::text NOT NULL,
    template_id uuid,
    template_name text,
    recipient_id text,
    recipient_email text,
    recipient_phone text,
    recipient_token text,
    subject text,
    body text,
    body_html text,
    variables jsonb,
    metadata jsonb,
    scheduled_for timestamp with time zone,
    sent_at timestamp with time zone,
    delivered_at timestamp with time zone,
    failed_at timestamp with time zone,
    error_message text,
    retry_count bigint DEFAULT 0,
    max_retries bigint DEFAULT 3,
    provider text,
    provider_id text,
    provider_data jsonb,
    opened_at timestamp with time zone,
    clicked_at timestamp with time zone,
    unsubscribed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    user_id uuid,
    type character varying(100) DEFAULT ''::character varying,
    title character varying(500) DEFAULT ''::character varying,
    message text,
    icon character varying(255),
    action_url character varying(2048),
    source_service character varying(100) DEFAULT ''::character varying,
    source_event_id character varying(255),
    entity_type character varying(100),
    entity_id uuid,
    group_key character varying(255),
    group_count bigint DEFAULT 1,
    is_read boolean DEFAULT false,
    read_at timestamp with time zone,
    is_archived boolean DEFAULT false,
    archived_at timestamp with time zone,
    expires_at timestamp with time zone
);


ALTER TABLE public.notifications OWNER TO postgres;

--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.schema_migrations (
    filename character varying(255) NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.schema_migrations OWNER TO postgres;

--
-- Name: notification_batches notification_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_batches
    ADD CONSTRAINT notification_batches_pkey PRIMARY KEY (id);


--
-- Name: notification_logs notification_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_logs
    ADD CONSTRAINT notification_logs_pkey PRIMARY KEY (id);


--
-- Name: notification_preferences notification_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_pkey PRIMARY KEY (id);


--
-- Name: notification_templates notification_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notification_templates
    ADD CONSTRAINT notification_templates_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (filename);


--
-- Name: idx_batches_scheduled_for; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_batches_scheduled_for ON public.notification_batches USING btree (scheduled_for);


--
-- Name: idx_batches_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_batches_status ON public.notification_batches USING btree (status);


--
-- Name: idx_batches_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_batches_tenant_id ON public.notification_batches USING btree (tenant_id);


--
-- Name: idx_logs_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_logs_created_at ON public.notification_logs USING btree (created_at);


--
-- Name: idx_logs_notification_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_logs_notification_id ON public.notification_logs USING btree (notification_id);


--
-- Name: idx_notification_batches_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notification_batches_tenant_id ON public.notification_batches USING btree (tenant_id);


--
-- Name: idx_notification_logs_notification_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notification_logs_notification_id ON public.notification_logs USING btree (notification_id);


--
-- Name: idx_notification_preferences_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notification_preferences_tenant_id ON public.notification_preferences USING btree (tenant_id);


--
-- Name: idx_notification_templates_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notification_templates_deleted_at ON public.notification_templates USING btree (deleted_at);


--
-- Name: idx_notification_templates_slug; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notification_templates_slug ON public.notification_templates USING btree (slug);


--
-- Name: idx_notification_templates_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notification_templates_tenant_id ON public.notification_templates USING btree (tenant_id);


--
-- Name: idx_notifications_channel; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_channel ON public.notifications USING btree (channel);


--
-- Name: idx_notifications_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_created_at ON public.notifications USING btree (created_at);


--
-- Name: idx_notifications_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_deleted_at ON public.notifications USING btree (deleted_at);


--
-- Name: idx_notifications_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_expires_at ON public.notifications USING btree (expires_at);


--
-- Name: idx_notifications_group_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_group_key ON public.notifications USING btree (group_key);


--
-- Name: idx_notifications_recipient_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_recipient_email ON public.notifications USING btree (recipient_email);


--
-- Name: idx_notifications_recipient_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_recipient_id ON public.notifications USING btree (recipient_id);


--
-- Name: idx_notifications_scheduled_for; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_scheduled_for ON public.notifications USING btree (scheduled_for);


--
-- Name: idx_notifications_source_event_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_source_event_id ON public.notifications USING btree (source_event_id);


--
-- Name: idx_notifications_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_status ON public.notifications USING btree (status);


--
-- Name: idx_notifications_template_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_template_id ON public.notifications USING btree (template_id);


--
-- Name: idx_notifications_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_tenant_id ON public.notifications USING btree (tenant_id);


--
-- Name: idx_notifications_tenant_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_tenant_user ON public.notifications USING btree (tenant_id, user_id);


--
-- Name: idx_notifications_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_type ON public.notifications USING btree (type);


--
-- Name: idx_notifications_unread; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_unread ON public.notifications USING btree (is_read);


--
-- Name: idx_preferences_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_preferences_tenant_id ON public.notification_preferences USING btree (tenant_id);


--
-- Name: idx_preferences_tenant_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_preferences_tenant_user ON public.notification_preferences USING btree (tenant_id, user_id);


--
-- Name: idx_preferences_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_preferences_user_id ON public.notification_preferences USING btree (user_id);


--
-- Name: idx_template_slug_tenant; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_template_slug_tenant ON public.notification_templates USING btree (slug, tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_templates_category; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_templates_category ON public.notification_templates USING btree (category);


--
-- Name: idx_templates_channel; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_templates_channel ON public.notification_templates USING btree (channel);


--
-- Name: idx_templates_deleted_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_templates_deleted_at ON public.notification_templates USING btree (deleted_at);


--
-- Name: idx_templates_tenant_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_templates_tenant_id ON public.notification_templates USING btree (tenant_id);


--
-- PostgreSQL database dump complete
--

\unrestrict qVNofrsu9uknJ0XIhU64tF4QBIKhzWESbTdda65vv3CvqZ74hNI0I9ledzkp1d3

