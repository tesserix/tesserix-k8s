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

--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: approval_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.approval_audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    event_type character varying(50) NOT NULL,
    actor_id uuid,
    actor_role character varying(50),
    previous_state jsonb,
    new_state jsonb,
    metadata jsonb,
    created_at timestamp with time zone
);


--
-- Name: approval_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.approval_decisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    approver_id uuid NOT NULL,
    approver_role character varying(50),
    chain_index bigint DEFAULT 0,
    decision character varying(20) NOT NULL,
    comment text,
    conditions jsonb,
    decided_at timestamp with time zone
);


--
-- Name: approval_delegations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.approval_delegations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    delegator_id uuid NOT NULL,
    delegate_id uuid NOT NULL,
    workflow_id uuid,
    reason text,
    start_date timestamp with time zone NOT NULL,
    end_date timestamp with time zone NOT NULL,
    is_active boolean DEFAULT true,
    revoked_at timestamp with time zone,
    revoked_by uuid,
    revoke_reason text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


--
-- Name: approval_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.approval_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    workflow_id uuid NOT NULL,
    requester_id uuid NOT NULL,
    status character varying(30) DEFAULT 'pending'::character varying NOT NULL,
    version bigint DEFAULT 1 NOT NULL,
    action_type character varying(100) NOT NULL,
    action_data jsonb NOT NULL,
    resource_type character varying(50),
    resource_id uuid,
    reason text,
    priority character varying(20) DEFAULT 'normal'::character varying,
    current_chain_index bigint DEFAULT 0,
    completed_approvers uuid[],
    current_approver_id uuid,
    current_approver_role character varying(50),
    escalation_level bigint DEFAULT 0,
    escalated_at timestamp with time zone,
    escalated_from_id uuid,
    execution_id uuid,
    executed_at timestamp with time zone,
    execution_result jsonb,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    requester_name character varying(255)
);


--
-- Name: approval_workflows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.approval_workflows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    name character varying(100) NOT NULL,
    display_name character varying(255) NOT NULL,
    description text,
    trigger_type character varying(50) NOT NULL,
    trigger_config jsonb NOT NULL,
    approver_config jsonb NOT NULL,
    approval_chain jsonb,
    timeout_hours bigint DEFAULT 72,
    escalation_config jsonb,
    notification_config jsonb,
    is_active boolean DEFAULT true,
    is_system boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);


--
-- Name: approval_audit_log approval_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_audit_log
    ADD CONSTRAINT approval_audit_log_pkey PRIMARY KEY (id);


--
-- Name: approval_decisions approval_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_decisions
    ADD CONSTRAINT approval_decisions_pkey PRIMARY KEY (id);


--
-- Name: approval_delegations approval_delegations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_delegations
    ADD CONSTRAINT approval_delegations_pkey PRIMARY KEY (id);


--
-- Name: approval_requests approval_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT approval_requests_pkey PRIMARY KEY (id);


--
-- Name: approval_workflows approval_workflows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_workflows
    ADD CONSTRAINT approval_workflows_pkey PRIMARY KEY (id);


--
-- Name: idx_approval_audit_log_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_audit_log_event_type ON public.approval_audit_log USING btree (event_type);


--
-- Name: idx_approval_audit_log_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_audit_log_request_id ON public.approval_audit_log USING btree (request_id);


--
-- Name: idx_approval_audit_log_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_audit_log_tenant_id ON public.approval_audit_log USING btree (tenant_id);


--
-- Name: idx_approval_decisions_approver_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_decisions_approver_id ON public.approval_decisions USING btree (approver_id);


--
-- Name: idx_approval_decisions_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_decisions_request_id ON public.approval_decisions USING btree (request_id);


--
-- Name: idx_approval_delegations_delegate_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_delegations_delegate_id ON public.approval_delegations USING btree (delegate_id);


--
-- Name: idx_approval_delegations_delegator_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_delegations_delegator_id ON public.approval_delegations USING btree (delegator_id);


--
-- Name: idx_approval_delegations_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_delegations_tenant_id ON public.approval_delegations USING btree (tenant_id);


--
-- Name: idx_approval_delegations_workflow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_delegations_workflow_id ON public.approval_delegations USING btree (workflow_id);


--
-- Name: idx_approval_requests_execution_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_approval_requests_execution_id ON public.approval_requests USING btree (execution_id);


--
-- Name: idx_approval_requests_requester_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_requests_requester_id ON public.approval_requests USING btree (requester_id);


--
-- Name: idx_approval_requests_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_requests_status ON public.approval_requests USING btree (status);


--
-- Name: idx_approval_requests_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_requests_tenant_id ON public.approval_requests USING btree (tenant_id);


--
-- Name: idx_approval_requests_workflow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_requests_workflow_id ON public.approval_requests USING btree (workflow_id);


--
-- Name: idx_approval_workflows_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_workflows_deleted_at ON public.approval_workflows USING btree (deleted_at);


--
-- Name: idx_approval_workflows_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_approval_workflows_tenant_id ON public.approval_workflows USING btree (tenant_id);


--
-- Name: idx_audit_actor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_actor_id ON public.approval_audit_log USING btree (actor_id);


--
-- Name: idx_audit_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_event_type ON public.approval_audit_log USING btree (event_type);


--
-- Name: idx_audit_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_request_id ON public.approval_audit_log USING btree (request_id, created_at);


--
-- Name: idx_audit_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_audit_tenant_id ON public.approval_audit_log USING btree (tenant_id);


--
-- Name: idx_decisions_approver_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_decisions_approver_id ON public.approval_decisions USING btree (approver_id);


--
-- Name: idx_decisions_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_decisions_request_id ON public.approval_decisions USING btree (request_id);


--
-- Name: idx_delegations_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_delegations_active ON public.approval_delegations USING btree (is_active, start_date, end_date);


--
-- Name: idx_delegations_delegate; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_delegations_delegate ON public.approval_delegations USING btree (delegate_id);


--
-- Name: idx_delegations_delegator; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_delegations_delegator ON public.approval_delegations USING btree (delegator_id);


--
-- Name: idx_delegations_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_delegations_tenant ON public.approval_delegations USING btree (tenant_id);


--
-- Name: idx_requests_approver_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_requests_approver_id ON public.approval_requests USING btree (current_approver_id);


--
-- Name: idx_requests_execution_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_requests_execution_id ON public.approval_requests USING btree (execution_id);


--
-- Name: idx_requests_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_requests_expires ON public.approval_requests USING btree (expires_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: idx_requests_requester_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_requests_requester_id ON public.approval_requests USING btree (requester_id);


--
-- Name: idx_requests_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_requests_resource ON public.approval_requests USING btree (resource_type, resource_id);


--
-- Name: idx_requests_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_requests_status ON public.approval_requests USING btree (status);


--
-- Name: idx_requests_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_requests_tenant_id ON public.approval_requests USING btree (tenant_id);


--
-- Name: idx_requests_tenant_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_requests_tenant_status ON public.approval_requests USING btree (tenant_id, status);


--
-- Name: idx_requests_workflow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_requests_workflow_id ON public.approval_requests USING btree (workflow_id);


--
-- Name: idx_workflows_is_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_workflows_is_active ON public.approval_workflows USING btree (is_active);


--
-- Name: idx_workflows_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_workflows_name ON public.approval_workflows USING btree (name);


--
-- Name: idx_workflows_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_workflows_tenant_id ON public.approval_workflows USING btree (tenant_id);


--
-- Name: approval_decisions fk_approval_requests_decisions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_decisions
    ADD CONSTRAINT fk_approval_requests_decisions FOREIGN KEY (request_id) REFERENCES public.approval_requests(id);


--
-- Name: approval_requests fk_approval_requests_workflow; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approval_requests
    ADD CONSTRAINT fk_approval_requests_workflow FOREIGN KEY (workflow_id) REFERENCES public.approval_workflows(id);


--
-- PostgreSQL database dump complete
--


