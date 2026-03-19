-- location-service initial schema
-- Generated from GORM model definitions

CREATE TABLE IF NOT EXISTS countries (
    id varchar(2) PRIMARY KEY,
    name varchar(100) NOT NULL,
    native_name varchar(100),
    capital varchar(100),
    region varchar(50),
    subregion varchar(50),
    currency varchar(3),
    languages text,
    calling_code varchar(10),
    flag_emoji varchar(10),
    latitude double precision,
    longitude double precision,
    active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);

CREATE INDEX IF NOT EXISTS idx_countries_deleted_at ON countries (deleted_at);

CREATE TABLE IF NOT EXISTS states (
    id varchar(10) PRIMARY KEY,
    name varchar(100) NOT NULL,
    native_name varchar(100),
    code varchar(10) NOT NULL,
    country_id varchar(2) NOT NULL,
    type varchar(20) DEFAULT 'state',
    latitude double precision,
    longitude double precision,
    active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    CONSTRAINT fk_states_country FOREIGN KEY (country_id) REFERENCES countries(id)
);

CREATE INDEX IF NOT EXISTS idx_states_deleted_at ON states (deleted_at);

CREATE TABLE IF NOT EXISTS currencies (
    code varchar(3) PRIMARY KEY,
    name varchar(100) NOT NULL,
    symbol varchar(10) NOT NULL,
    decimal_places integer DEFAULT 2,
    active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);

CREATE INDEX IF NOT EXISTS idx_currencies_deleted_at ON currencies (deleted_at);

CREATE TABLE IF NOT EXISTS timezones (
    id varchar(50) PRIMARY KEY,
    name varchar(100) NOT NULL,
    abbreviation varchar(10),
    "offset" varchar(10) NOT NULL,
    dst boolean DEFAULT false,
    countries text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);

CREATE INDEX IF NOT EXISTS idx_timezones_deleted_at ON timezones (deleted_at);

CREATE TABLE IF NOT EXISTS location_cache (
    id bigserial PRIMARY KEY,
    ip varchar(45) NOT NULL,
    country_id varchar(2),
    state_id varchar(10),
    city varchar(100),
    postal_code varchar(20),
    latitude double precision,
    longitude double precision,
    timezone_id varchar(50),
    isp varchar(200),
    expires_at timestamp with time zone,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    CONSTRAINT fk_location_cache_country FOREIGN KEY (country_id) REFERENCES countries(id),
    CONSTRAINT fk_location_cache_state FOREIGN KEY (state_id) REFERENCES states(id),
    CONSTRAINT fk_location_cache_timezone FOREIGN KEY (timezone_id) REFERENCES timezones(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_location_cache_ip ON location_cache (ip);
CREATE INDEX IF NOT EXISTS idx_location_cache_expires_at ON location_cache (expires_at);

CREATE TABLE IF NOT EXISTS address_cache (
    id bigserial PRIMARY KEY,
    cache_type varchar(20) NOT NULL,
    cache_key_hash varchar(64) NOT NULL,
    cache_key text NOT NULL,
    formatted_address varchar(500),
    place_id varchar(500),
    latitude double precision,
    longitude double precision,
    street_number varchar(50),
    street_name varchar(255),
    city varchar(255),
    district varchar(255),
    state_code varchar(10),
    state_name varchar(255),
    country_code varchar(2),
    country_name varchar(100),
    postal_code varchar(20),
    response_json jsonb,
    provider varchar(50) NOT NULL,
    hit_count integer DEFAULT 0,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);

CREATE INDEX IF NOT EXISTS idx_cache_lookup ON address_cache (cache_type, cache_key_hash);
CREATE INDEX IF NOT EXISTS idx_address_cache_expires_at ON address_cache (expires_at);

CREATE TABLE IF NOT EXISTS places (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_place_id varchar(500),
    formatted_address text NOT NULL,
    latitude numeric(10,8) NOT NULL,
    longitude numeric(11,8) NOT NULL,
    geohash varchar(12),
    street_number varchar(50),
    street_name varchar(255),
    city varchar(255),
    district varchar(255),
    state_code varchar(10),
    state_name varchar(255),
    country_code varchar(2),
    country_name varchar(100),
    postal_code varchar(20),
    place_types text[],
    source_provider varchar(50),
    confidence numeric(3,2),
    verified boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone
);

CREATE INDEX IF NOT EXISTS idx_places_city ON places (city, country_code);
CREATE INDEX IF NOT EXISTS idx_places_deleted_at ON places (deleted_at);

CREATE TABLE IF NOT EXISTS addresses (
    id bigserial PRIMARY KEY,
    formatted_address varchar(500) NOT NULL,
    street_number varchar(20),
    route varchar(200),
    locality varchar(100),
    sublocality varchar(100),
    admin_area_level_1 varchar(100),
    admin_area_level_2 varchar(100),
    country_id varchar(2),
    country_name varchar(100),
    postal_code varchar(20),
    latitude double precision,
    longitude double precision,
    place_id varchar(500),
    types text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    deleted_at timestamp with time zone,
    CONSTRAINT fk_addresses_country FOREIGN KEY (country_id) REFERENCES countries(id)
);

CREATE INDEX IF NOT EXISTS idx_addresses_place_id ON addresses (place_id);
CREATE INDEX IF NOT EXISTS idx_addresses_deleted_at ON addresses (deleted_at);
