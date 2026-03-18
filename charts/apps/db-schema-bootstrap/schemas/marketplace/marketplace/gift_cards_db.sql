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
-- Name: gift_card_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.gift_card_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    gift_card_id uuid NOT NULL,
    type character varying(20) NOT NULL,
    amount numeric(10,2) NOT NULL,
    balance_before numeric(10,2) NOT NULL,
    balance_after numeric(10,2) NOT NULL,
    order_id uuid,
    user_id uuid,
    description text,
    metadata jsonb,
    created_at timestamp with time zone,
    created_by text
);


--
-- Name: gift_cards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.gift_cards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id character varying(255) NOT NULL,
    code character varying(50) NOT NULL,
    initial_balance numeric(10,2) NOT NULL,
    current_balance numeric(10,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'USD'::character varying NOT NULL,
    status character varying(20) DEFAULT 'ACTIVE'::character varying NOT NULL,
    recipient_email character varying(255),
    recipient_name character varying(255),
    sender_name character varying(255),
    message text,
    purchased_by uuid,
    purchase_order_id uuid,
    purchase_date timestamp with time zone,
    expires_at timestamp with time zone,
    last_used_at timestamp with time zone,
    usage_count bigint DEFAULT 0,
    metadata jsonb,
    notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    created_by text,
    updated_by text
);


--
-- Name: gift_card_transactions gift_card_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gift_card_transactions
    ADD CONSTRAINT gift_card_transactions_pkey PRIMARY KEY (id);


--
-- Name: gift_cards gift_cards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gift_cards
    ADD CONSTRAINT gift_cards_pkey PRIMARY KEY (id);


--
-- Name: idx_gift_card_transactions_gift_card_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gift_card_transactions_gift_card_id ON public.gift_card_transactions USING btree (gift_card_id);


--
-- Name: idx_gift_card_transactions_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gift_card_transactions_order_id ON public.gift_card_transactions USING btree (order_id);


--
-- Name: idx_gift_card_transactions_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gift_card_transactions_tenant_id ON public.gift_card_transactions USING btree (tenant_id);


--
-- Name: idx_gift_cards_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX IF NOT EXISTS idx_gift_cards_code ON public.gift_cards USING btree (code);


--
-- Name: idx_gift_cards_deleted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gift_cards_deleted_at ON public.gift_cards USING btree (deleted_at);


--
-- Name: idx_gift_cards_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gift_cards_expires_at ON public.gift_cards USING btree (expires_at);


--
-- Name: idx_gift_cards_purchased_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gift_cards_purchased_by ON public.gift_cards USING btree (purchased_by);


--
-- Name: idx_gift_cards_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX IF NOT EXISTS idx_gift_cards_tenant_id ON public.gift_cards USING btree (tenant_id);


--
-- Name: gift_card_transactions fk_gift_cards_transactions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gift_card_transactions
    ADD CONSTRAINT fk_gift_cards_transactions FOREIGN KEY (gift_card_id) REFERENCES public.gift_cards(id);


--
-- PostgreSQL database dump complete
--


