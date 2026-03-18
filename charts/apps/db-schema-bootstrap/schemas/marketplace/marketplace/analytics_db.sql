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
-- Name: postgres_fdw; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgres_fdw WITH SCHEMA public;


--
-- Name: EXTENSION postgres_fdw; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION postgres_fdw IS 'foreign-data wrapper for remote PostgreSQL servers';


--
-- Name: customers_server; Type: SERVER; Schema: -; Owner: -
--

CREATE SERVER customers_server FOREIGN DATA WRAPPER postgres_fdw OPTIONS (
    dbname 'customers_db',
    host 'localhost',
    port '5432'
);


--
-- Name: USER MAPPING postgres SERVER customers_server; Type: USER MAPPING; Schema: -; Owner: -
--

CREATE USER MAPPING FOR postgres SERVER customers_server OPTIONS (
    password 'CsdxozUU35P9q7eYnoK69OJ3b3ndLBy',
    "user" 'postgres'
);


--
-- Name: orders_server; Type: SERVER; Schema: -; Owner: -
--

CREATE SERVER orders_server FOREIGN DATA WRAPPER postgres_fdw OPTIONS (
    dbname 'orders_db',
    host 'localhost',
    port '5432'
);


--
-- Name: USER MAPPING postgres SERVER orders_server; Type: USER MAPPING; Schema: -; Owner: -
--

CREATE USER MAPPING FOR postgres SERVER orders_server OPTIONS (
    password 'CsdxozUU35P9q7eYnoK69OJ3b3ndLBy',
    "user" 'postgres'
);


--
-- Name: products_server; Type: SERVER; Schema: -; Owner: -
--

CREATE SERVER products_server FOREIGN DATA WRAPPER postgres_fdw OPTIONS (
    dbname 'products_db',
    host 'localhost',
    port '5432'
);


--
-- Name: USER MAPPING postgres SERVER products_server; Type: USER MAPPING; Schema: -; Owner: -
--

CREATE USER MAPPING FOR postgres SERVER products_server OPTIONS (
    password 'CsdxozUU35P9q7eYnoK69OJ3b3ndLBy',
    "user" 'postgres'
);


--
-- Name: customers; Type: FOREIGN TABLE; Schema: public; Owner: -
--

CREATE FOREIGN TABLE IF NOT EXISTS public.customers (
    id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    user_id uuid,
    email character varying(255) NOT NULL,
    first_name character varying(100) NOT NULL,
    last_name character varying(100) NOT NULL,
    phone character varying(50),
    status character varying(20),
    customer_type character varying(20),
    total_orders bigint,
    total_spent numeric(12,2),
    average_order_value numeric(10,2),
    lifetime_value numeric(12,2),
    last_order_date timestamp with time zone,
    first_order_date timestamp with time zone,
    tags text[],
    notes text,
    marketing_opt_in boolean,
    email_verified boolean,
    verification_token character varying(255),
    verification_token_expires_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
)
SERVER customers_server
OPTIONS (
    schema_name 'public',
    table_name 'customers'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN id OPTIONS (
    column_name 'id'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN tenant_id OPTIONS (
    column_name 'tenant_id'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN user_id OPTIONS (
    column_name 'user_id'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN email OPTIONS (
    column_name 'email'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN first_name OPTIONS (
    column_name 'first_name'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN last_name OPTIONS (
    column_name 'last_name'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN phone OPTIONS (
    column_name 'phone'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN status OPTIONS (
    column_name 'status'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN customer_type OPTIONS (
    column_name 'customer_type'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN total_orders OPTIONS (
    column_name 'total_orders'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN total_spent OPTIONS (
    column_name 'total_spent'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN average_order_value OPTIONS (
    column_name 'average_order_value'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN lifetime_value OPTIONS (
    column_name 'lifetime_value'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN last_order_date OPTIONS (
    column_name 'last_order_date'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN first_order_date OPTIONS (
    column_name 'first_order_date'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN tags OPTIONS (
    column_name 'tags'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN notes OPTIONS (
    column_name 'notes'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN marketing_opt_in OPTIONS (
    column_name 'marketing_opt_in'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN email_verified OPTIONS (
    column_name 'email_verified'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN verification_token OPTIONS (
    column_name 'verification_token'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN verification_token_expires_at OPTIONS (
    column_name 'verification_token_expires_at'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN created_at OPTIONS (
    column_name 'created_at'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN updated_at OPTIONS (
    column_name 'updated_at'
);
ALTER FOREIGN TABLE public.customers ALTER COLUMN deleted_at OPTIONS (
    column_name 'deleted_at'
);


--
-- Name: order_items; Type: FOREIGN TABLE; Schema: public; Owner: -
--

CREATE FOREIGN TABLE IF NOT EXISTS public.order_items (
    id uuid NOT NULL,
    order_id uuid NOT NULL,
    vendor_id character varying(255),
    product_id uuid NOT NULL,
    product_name text NOT NULL,
    sku text NOT NULL,
    image character varying(500),
    quantity bigint NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    total_price numeric(10,2) NOT NULL,
    tax_amount numeric(10,2),
    tax_rate numeric(5,2),
    hsn_code character varying(10),
    sac_code character varying(10),
    gst_slab numeric(5,2),
    cgst_amount numeric(10,2),
    sgst_amount numeric(10,2),
    igst_amount numeric(10,2),
    created_at timestamp with time zone,
    updated_at timestamp with time zone
)
SERVER orders_server
OPTIONS (
    schema_name 'public',
    table_name 'order_items'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN id OPTIONS (
    column_name 'id'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN order_id OPTIONS (
    column_name 'order_id'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN vendor_id OPTIONS (
    column_name 'vendor_id'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN product_id OPTIONS (
    column_name 'product_id'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN product_name OPTIONS (
    column_name 'product_name'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN sku OPTIONS (
    column_name 'sku'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN image OPTIONS (
    column_name 'image'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN quantity OPTIONS (
    column_name 'quantity'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN unit_price OPTIONS (
    column_name 'unit_price'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN total_price OPTIONS (
    column_name 'total_price'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN tax_amount OPTIONS (
    column_name 'tax_amount'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN tax_rate OPTIONS (
    column_name 'tax_rate'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN hsn_code OPTIONS (
    column_name 'hsn_code'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN sac_code OPTIONS (
    column_name 'sac_code'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN gst_slab OPTIONS (
    column_name 'gst_slab'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN cgst_amount OPTIONS (
    column_name 'cgst_amount'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN sgst_amount OPTIONS (
    column_name 'sgst_amount'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN igst_amount OPTIONS (
    column_name 'igst_amount'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN created_at OPTIONS (
    column_name 'created_at'
);
ALTER FOREIGN TABLE public.order_items ALTER COLUMN updated_at OPTIONS (
    column_name 'updated_at'
);


--
-- Name: orders; Type: FOREIGN TABLE; Schema: public; Owner: -
--

CREATE FOREIGN TABLE IF NOT EXISTS public.orders (
    id uuid NOT NULL,
    tenant_id character varying(255) NOT NULL,
    vendor_id character varying(255),
    order_number text NOT NULL,
    customer_id uuid NOT NULL,
    status character varying(20) NOT NULL,
    payment_status character varying(30) NOT NULL,
    fulfillment_status character varying(30) NOT NULL,
    currency character varying(3) NOT NULL,
    subtotal numeric(10,2) NOT NULL,
    tax_amount numeric(10,2),
    shipping_cost numeric(10,2),
    discount_amount numeric(10,2),
    total numeric(10,2) NOT NULL,
    notes text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    parent_order_id uuid,
    is_split boolean,
    split_reason character varying(50),
    tax_breakdown jsonb,
    cgst numeric(10,2),
    sgst numeric(10,2),
    igst numeric(10,2),
    utgst numeric(10,2),
    gst_cess numeric(10,2),
    is_interstate boolean,
    customer_gstin character varying(15),
    vat_amount numeric(10,2),
    is_reverse_charge boolean,
    customer_vat_number character varying(50)
)
SERVER orders_server
OPTIONS (
    schema_name 'public',
    table_name 'orders'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN id OPTIONS (
    column_name 'id'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN tenant_id OPTIONS (
    column_name 'tenant_id'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN vendor_id OPTIONS (
    column_name 'vendor_id'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN order_number OPTIONS (
    column_name 'order_number'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN customer_id OPTIONS (
    column_name 'customer_id'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN status OPTIONS (
    column_name 'status'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN payment_status OPTIONS (
    column_name 'payment_status'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN fulfillment_status OPTIONS (
    column_name 'fulfillment_status'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN currency OPTIONS (
    column_name 'currency'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN subtotal OPTIONS (
    column_name 'subtotal'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN tax_amount OPTIONS (
    column_name 'tax_amount'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN shipping_cost OPTIONS (
    column_name 'shipping_cost'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN discount_amount OPTIONS (
    column_name 'discount_amount'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN total OPTIONS (
    column_name 'total'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN notes OPTIONS (
    column_name 'notes'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN created_at OPTIONS (
    column_name 'created_at'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN updated_at OPTIONS (
    column_name 'updated_at'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN deleted_at OPTIONS (
    column_name 'deleted_at'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN parent_order_id OPTIONS (
    column_name 'parent_order_id'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN is_split OPTIONS (
    column_name 'is_split'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN split_reason OPTIONS (
    column_name 'split_reason'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN tax_breakdown OPTIONS (
    column_name 'tax_breakdown'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN cgst OPTIONS (
    column_name 'cgst'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN sgst OPTIONS (
    column_name 'sgst'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN igst OPTIONS (
    column_name 'igst'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN utgst OPTIONS (
    column_name 'utgst'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN gst_cess OPTIONS (
    column_name 'gst_cess'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN is_interstate OPTIONS (
    column_name 'is_interstate'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN customer_gstin OPTIONS (
    column_name 'customer_gstin'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN vat_amount OPTIONS (
    column_name 'vat_amount'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN is_reverse_charge OPTIONS (
    column_name 'is_reverse_charge'
);
ALTER FOREIGN TABLE public.orders ALTER COLUMN customer_vat_number OPTIONS (
    column_name 'customer_vat_number'
);


--
-- Name: products; Type: FOREIGN TABLE; Schema: public; Owner: -
--

CREATE FOREIGN TABLE IF NOT EXISTS public.products (
    id uuid NOT NULL,
    tenant_id text NOT NULL,
    vendor_id text NOT NULL,
    category_id text NOT NULL,
    created_by_id text,
    name text NOT NULL,
    slug text,
    sku text NOT NULL,
    brand text,
    description text,
    price text NOT NULL,
    compare_price text,
    cost_price text,
    status text NOT NULL,
    inventory_status text,
    quantity bigint,
    min_order_qty bigint,
    max_order_qty bigint,
    low_stock_threshold bigint,
    weight text,
    dimensions jsonb,
    search_keywords text,
    search_vector tsvector,
    average_rating numeric(3,2),
    review_count bigint,
    tags jsonb,
    currency_code text,
    sync_status text,
    synced_at timestamp without time zone,
    version bigint,
    offline_id text,
    localizations jsonb,
    attributes jsonb,
    images jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp without time zone,
    created_by text,
    updated_by text,
    metadata jsonb,
    warehouse_id text,
    supplier_id text,
    logo_url text,
    banner_url text,
    videos jsonb,
    warehouse_name text,
    supplier_name text
)
SERVER products_server
OPTIONS (
    schema_name 'public',
    table_name 'products'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN id OPTIONS (
    column_name 'id'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN tenant_id OPTIONS (
    column_name 'tenant_id'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN vendor_id OPTIONS (
    column_name 'vendor_id'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN category_id OPTIONS (
    column_name 'category_id'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN created_by_id OPTIONS (
    column_name 'created_by_id'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN name OPTIONS (
    column_name 'name'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN slug OPTIONS (
    column_name 'slug'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN sku OPTIONS (
    column_name 'sku'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN brand OPTIONS (
    column_name 'brand'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN description OPTIONS (
    column_name 'description'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN price OPTIONS (
    column_name 'price'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN compare_price OPTIONS (
    column_name 'compare_price'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN cost_price OPTIONS (
    column_name 'cost_price'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN status OPTIONS (
    column_name 'status'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN inventory_status OPTIONS (
    column_name 'inventory_status'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN quantity OPTIONS (
    column_name 'quantity'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN min_order_qty OPTIONS (
    column_name 'min_order_qty'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN max_order_qty OPTIONS (
    column_name 'max_order_qty'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN low_stock_threshold OPTIONS (
    column_name 'low_stock_threshold'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN weight OPTIONS (
    column_name 'weight'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN dimensions OPTIONS (
    column_name 'dimensions'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN search_keywords OPTIONS (
    column_name 'search_keywords'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN search_vector OPTIONS (
    column_name 'search_vector'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN average_rating OPTIONS (
    column_name 'average_rating'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN review_count OPTIONS (
    column_name 'review_count'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN tags OPTIONS (
    column_name 'tags'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN currency_code OPTIONS (
    column_name 'currency_code'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN sync_status OPTIONS (
    column_name 'sync_status'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN synced_at OPTIONS (
    column_name 'synced_at'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN version OPTIONS (
    column_name 'version'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN offline_id OPTIONS (
    column_name 'offline_id'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN localizations OPTIONS (
    column_name 'localizations'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN attributes OPTIONS (
    column_name 'attributes'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN images OPTIONS (
    column_name 'images'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN created_at OPTIONS (
    column_name 'created_at'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN updated_at OPTIONS (
    column_name 'updated_at'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN deleted_at OPTIONS (
    column_name 'deleted_at'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN created_by OPTIONS (
    column_name 'created_by'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN updated_by OPTIONS (
    column_name 'updated_by'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN metadata OPTIONS (
    column_name 'metadata'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN warehouse_id OPTIONS (
    column_name 'warehouse_id'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN supplier_id OPTIONS (
    column_name 'supplier_id'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN logo_url OPTIONS (
    column_name 'logo_url'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN banner_url OPTIONS (
    column_name 'banner_url'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN videos OPTIONS (
    column_name 'videos'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN warehouse_name OPTIONS (
    column_name 'warehouse_name'
);
ALTER FOREIGN TABLE public.products ALTER COLUMN supplier_name OPTIONS (
    column_name 'supplier_name'
);


--
-- PostgreSQL database dump complete
--


