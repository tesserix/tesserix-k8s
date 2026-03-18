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
-- Name: notification_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.notification_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    template_id uuid NOT NULL,
    channel character varying(20) NOT NULL,
    total_count bigint DEFAULT 0,
    sent_count bigint DEFAULT 0,
    failed_count bigint DEFAULT 0,
    status character varying(50) DEFAULT 'PENDING'::character varying,
    scheduled_for timestamp with time zone,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: notification_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.notification_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    notification_id uuid NOT NULL,
    event character varying(100) NOT NULL,
    status character varying(20) NOT NULL,
    message text,
    data jsonb,
    created_at timestamp with time zone
);


--
-- Name: notification_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.notification_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    user_id uuid NOT NULL,
    websocket_enabled boolean DEFAULT true,
    sse_enabled boolean DEFAULT true,
    category_preferences jsonb DEFAULT '{}'::jsonb,
    sound_enabled boolean DEFAULT true,
    vibration_enabled boolean DEFAULT true,
    quiet_hours_enabled boolean DEFAULT false,
    quiet_hours_start timestamp with time zone,
    quiet_hours_end timestamp with time zone,
    quiet_hours_timezone character varying(50),
    group_similar boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    email_enabled boolean DEFAULT true,
    sms_enabled boolean DEFAULT true,
    push_enabled boolean DEFAULT true,
    marketing_enabled boolean DEFAULT true,
    orders_enabled boolean DEFAULT true,
    security_enabled boolean DEFAULT true,
    email character varying(255),
    phone character varying(50),
    push_tokens jsonb
);


--
-- Name: notification_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.notification_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    channel character varying(20) NOT NULL,
    category character varying(100),
    subject character varying(500),
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


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    user_id uuid NOT NULL,
    channel character varying(20) DEFAULT 'in_app'::character varying NOT NULL,
    type character varying(100) NOT NULL,
    title character varying(500) NOT NULL,
    message text,
    icon character varying(255),
    action_url character varying(2048),
    source_service character varying(100) NOT NULL,
    source_event_id character varying(255),
    entity_type character varying(100),
    entity_id uuid,
    metadata jsonb,
    group_key character varying(255),
    group_count bigint DEFAULT 1,
    is_read boolean DEFAULT false,
    read_at timestamp with time zone,
    is_archived boolean DEFAULT false,
    archived_at timestamp with time zone,
    priority character varying(20) DEFAULT 'NORMAL'::character varying,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    expires_at timestamp with time zone,
    status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    template_id uuid,
    template_name character varying(255),
    recipient_id uuid,
    recipient_email character varying(255),
    recipient_phone character varying(50),
    recipient_token text,
    subject character varying(500),
    body text,
    body_html text,
    variables jsonb,
    scheduled_for timestamp with time zone,
    sent_at timestamp with time zone,
    delivered_at timestamp with time zone,
    failed_at timestamp with time zone,
    error_message text,
    retry_count bigint DEFAULT 0,
    max_retries bigint DEFAULT 3,
    provider character varying(100),
    provider_id character varying(255),
    provider_data jsonb,
    opened_at timestamp with time zone,
    clicked_at timestamp with time zone,
    unsubscribed_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: notification_batches notification_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_batches
    ADD CONSTRAINT notification_batches_pkey PRIMARY KEY (id);


--
-- Name: notification_logs notification_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_logs
    ADD CONSTRAINT notification_logs_pkey PRIMARY KEY (id);


--
-- Name: notification_preferences notification_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_preferences
    ADD CONSTRAINT notification_preferences_pkey PRIMARY KEY (id);


--
-- Name: notification_templates notification_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_templates
    ADD CONSTRAINT notification_templates_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: idx_notification_batches_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notification_batches_tenant_id ON public.notification_batches USING btree (tenant_id);


--
-- Name: idx_notification_logs_notification_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notification_logs_notification_id ON public.notification_logs USING btree (notification_id);


--
-- Name: idx_notification_preferences_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notification_preferences_tenant_id ON public.notification_preferences USING btree (tenant_id);


--
-- Name: idx_notification_templates_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notification_templates_category ON public.notification_templates USING btree (category);


--
-- Name: idx_notification_templates_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notification_templates_deleted_at ON public.notification_templates USING btree (deleted_at);


--
-- Name: idx_notification_templates_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notification_templates_tenant_id ON public.notification_templates USING btree (tenant_id);


--
-- Name: idx_notifications_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_channel ON public.notifications USING btree (channel);


--
-- Name: idx_notifications_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_deleted_at ON public.notifications USING btree (deleted_at);


--
-- Name: idx_notifications_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_expires_at ON public.notifications USING btree (expires_at);


--
-- Name: idx_notifications_group_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_group_key ON public.notifications USING btree (group_key);


--
-- Name: idx_notifications_is_read; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_is_read ON public.notifications USING btree (is_read);


--
-- Name: idx_notifications_recipient_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_recipient_email ON public.notifications USING btree (recipient_email);


--
-- Name: idx_notifications_recipient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_recipient_id ON public.notifications USING btree (recipient_id);


--
-- Name: idx_notifications_source_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_source_event_id ON public.notifications USING btree (source_event_id);


--
-- Name: idx_notifications_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_status ON public.notifications USING btree (status);


--
-- Name: idx_notifications_template_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_template_id ON public.notifications USING btree (template_id);


--
-- Name: idx_notifications_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_tenant_id ON public.notifications USING btree (tenant_id);


--
-- Name: idx_notifications_tenant_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_tenant_user ON public.notifications USING btree (tenant_id, user_id);


--
-- Name: idx_notifications_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_type ON public.notifications USING btree (type);


--
-- Name: idx_notifications_unread; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_unread ON public.notifications USING btree (is_read);


--
-- Name: idx_notifications_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON public.notifications USING btree (user_id);


--
-- Name: idx_preferences_tenant_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_preferences_tenant_user ON public.notification_preferences USING btree (tenant_id, user_id);


--
-- Name: idx_template_name_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_template_name_tenant ON public.notification_templates USING btree (name);


--
-- Name: idx_user_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_tenant ON public.notification_preferences USING btree (user_id);


--
-- PostgreSQL database dump complete
--


