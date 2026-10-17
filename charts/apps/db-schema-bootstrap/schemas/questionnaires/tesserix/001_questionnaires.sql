BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
REVOKE ALL ON DATABASE questionnaires FROM PUBLIC;
GRANT CONNECT ON DATABASE questionnaires TO questionnaires_writer, questionnaires_reader;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA IF NOT EXISTS vending_customers;
CREATE SCHEMA IF NOT EXISTS vending_business;
CREATE SCHEMA IF NOT EXISTS questionnaires_api;
REVOKE ALL ON SCHEMA vending_customers, vending_business, questionnaires_api FROM PUBLIC;
CREATE TABLE IF NOT EXISTS vending_customers.responses (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 request_key uuid NOT NULL UNIQUE,
 version integer NOT NULL CHECK(version=1),
 venue_type text NOT NULL CHECK(venue_type IN ('gym','shopping-centre','office','university','hospital','transport-hub','residential','other')),
 country text NOT NULL CHECK(country ~ '^[A-Z]{2}$'),
 city text NOT NULL CHECK(length(city) BETWEEN 1 AND 200),
 campaign text NOT NULL DEFAULT '' CHECK(length(campaign)<=200),
 currency text NOT NULL CHECK(currency IN ('AUD','NZD','INR','USD','GBP','EUR','SGD','AED')),
 snack_price_minor integer CHECK(snack_price_minor BETWEEN 0 AND 1000000),
 drink_price_minor integer CHECK(drink_price_minor BETWEEN 0 AND 1000000),
 answers jsonb NOT NULL CHECK(jsonb_typeof(answers)='object' AND octet_length(answers::text)<=16384 AND answers->'consent'='true'::jsonb AND answers->>'website'=''),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS vending_business.responses (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 request_key uuid NOT NULL UNIQUE,
 version integer NOT NULL CHECK(version=1),
 venue_type text NOT NULL CHECK(venue_type IN ('gym','shopping-centre','office','university','hospital','transport-hub','residential','other')),
 country text NOT NULL CHECK(country ~ '^[A-Z]{2}$'),
 city text NOT NULL CHECK(length(city) BETWEEN 1 AND 200),
 campaign text NOT NULL DEFAULT '' CHECK(length(campaign)<=200),
 currency text NOT NULL CHECK(currency IN ('AUD','NZD','INR','USD','GBP','EUR','SGD','AED')),
 answers jsonb NOT NULL CHECK(jsonb_typeof(answers)='object' AND octet_length(answers::text)<=16384 AND answers->'consent'='true'::jsonb AND answers->>'website'=''),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS vending_customers.product_preferences (
 response_id bigint NOT NULL REFERENCES vending_customers.responses(id) ON DELETE CASCADE,
 product text NOT NULL CHECK(product IN ('water','sparkling-water','electrolyte-drinks','protein-shakes','fresh-juice','low-sugar-drinks','coffee-tea','energy-drinks','protein-bars','nuts-seeds','fruit','yoghurt','sandwiches-wraps','savoury-snacks','chocolate','confectionery')),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(response_id,product)
);
CREATE INDEX IF NOT EXISTS customer_segment_recent ON vending_customers.responses(venue_type,country,campaign,id DESC);
CREATE INDEX IF NOT EXISTS business_segment_recent ON vending_business.responses(venue_type,country,campaign,id DESC);
CREATE INDEX IF NOT EXISTS customer_product_votes ON vending_customers.product_preferences(product,response_id);
CREATE TABLE IF NOT EXISTS questionnaires_api.rate_limits (
 bucket text NOT NULL, period timestamptz NOT NULL, hits integer NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(bucket,period)
);
CREATE INDEX IF NOT EXISTS rate_limits_expiry ON questionnaires_api.rate_limits(period);
CREATE OR REPLACE FUNCTION questionnaires_api.submit(p_form text,p_key uuid,p_answers jsonb,p_fingerprint text,p_snack integer,p_drink integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE old_answers jsonb; response_id bigint; amount integer;
BEGIN
 IF p_form NOT IN ('vending-customers','vending-business') OR p_key IS NULL OR p_answers IS NULL OR p_answers->>'version' IS DISTINCT FROM '1' OR p_answers->'consent' IS DISTINCT FROM 'true'::jsonb OR p_answers->>'website' IS DISTINCT FROM '' OR octet_length(p_answers::text)>16384 OR p_fingerprint IS NULL OR p_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'Invalid questionnaire' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_form||p_key::text,0));
 IF p_form='vending-customers' THEN SELECT answers INTO old_answers FROM vending_customers.responses WHERE request_key=p_key;
 ELSE SELECT answers INTO old_answers FROM vending_business.responses WHERE request_key=p_key; END IF;
 IF old_answers IS NOT NULL THEN
  IF old_answers<>p_answers THEN RAISE EXCEPTION 'Submission intent conflict' USING ERRCODE='P0002'; END IF;
  RETURN p_key;
 END IF;
 DELETE FROM questionnaires_api.rate_limits WHERE period < now()-interval '1 day';
 INSERT INTO questionnaires_api.rate_limits(bucket,period,hits) VALUES('global',date_trunc('minute',now()),1)
 ON CONFLICT(bucket,period) DO UPDATE SET hits=questionnaires_api.rate_limits.hits+1,updated_at=now() RETURNING hits INTO amount;
 IF amount>120 THEN RAISE EXCEPTION 'Submission limit' USING ERRCODE='P0003'; END IF;
 INSERT INTO questionnaires_api.rate_limits(bucket,period,hits) VALUES(p_fingerprint,date_trunc('hour',now()),1)
 ON CONFLICT(bucket,period) DO UPDATE SET hits=questionnaires_api.rate_limits.hits+1,updated_at=now() RETURNING hits INTO amount;
 IF amount>6 THEN RAISE EXCEPTION 'Submission limit' USING ERRCODE='P0003'; END IF;
 IF p_form='vending-customers' THEN
  IF jsonb_typeof(p_answers->'products') IS DISTINCT FROM 'array' OR jsonb_array_length(p_answers->'products')>5 THEN RAISE EXCEPTION 'Invalid products' USING ERRCODE='22023'; END IF;
  INSERT INTO vending_customers.responses(request_key,version,venue_type,country,city,campaign,currency,snack_price_minor,drink_price_minor,answers)
  VALUES(p_key,1,p_answers->>'venueType',p_answers->>'country',p_answers->>'city',coalesce(p_answers->>'campaign',''),p_answers->>'currency',p_snack,p_drink,p_answers) RETURNING id INTO response_id;
  INSERT INTO vending_customers.product_preferences(response_id,product) SELECT response_id,value FROM jsonb_array_elements_text(p_answers->'products');
 ELSE
  IF nullif(p_answers->>'businessName','') IS NULL OR ((p_answers->>'commercialModel') IS DISTINCT FROM 'not-interested' AND (nullif(p_answers->>'contactName','') IS NULL OR nullif(p_answers->>'contactEmail','') IS NULL)) THEN RAISE EXCEPTION 'Business contact required' USING ERRCODE='22023'; END IF;
  INSERT INTO vending_business.responses(request_key,version,venue_type,country,city,campaign,currency,answers)
  VALUES(p_key,1,p_answers->>'venueType',p_answers->>'country',p_answers->>'city',coalesce(p_answers->>'campaign',''),p_answers->>'currency',p_answers);
 END IF;
 RETURN p_key;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA vending_customers,vending_business,questionnaires_api FROM PUBLIC,questionnaires_writer,questionnaires_reader;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA vending_customers,vending_business,questionnaires_api FROM PUBLIC,questionnaires_writer,questionnaires_reader;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA questionnaires_api FROM PUBLIC,questionnaires_reader;
GRANT USAGE ON SCHEMA questionnaires_api TO questionnaires_writer;
GRANT EXECUTE ON FUNCTION questionnaires_api.submit(text,uuid,jsonb,text,integer,integer) TO questionnaires_writer;
GRANT USAGE ON SCHEMA vending_customers,vending_business TO questionnaires_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA vending_customers,vending_business TO questionnaires_reader;
COMMIT;
