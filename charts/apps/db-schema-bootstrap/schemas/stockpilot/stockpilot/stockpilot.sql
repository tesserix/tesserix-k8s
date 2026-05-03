-- ============================================================
-- StockPilot Database Bootstrap
-- Fully idempotent: safe to run on every container startup.
-- Creates schema, tables, hypertables, policies, and seed data
-- only when they do not already exist.
-- ============================================================

-- Extensions (optional — TimescaleDB and pgvector may not be available)
DO $$ BEGIN CREATE EXTENSION IF NOT EXISTS timescaledb; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'timescaledb not available, skipping'; END $$;
DO $$ BEGIN CREATE EXTENSION IF NOT EXISTS vector; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pgvector not available, skipping'; END $$;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- USERS & AUTH
-- ============================================================

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE NOT NULL,
    name TEXT,
    avatar_url TEXT,
    account_mode TEXT DEFAULT 'demo',
    demo_balance NUMERIC(14,2) DEFAULT 100000.00,
    broker_configured BOOLEAN DEFAULT FALSE,
    alpaca_account_id TEXT,
    ibkr_account_id TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Migration: add new columns if table already exists (idempotent)
DO $$ BEGIN
    ALTER TABLE users ADD COLUMN IF NOT EXISTS broker_configured BOOLEAN DEFAULT FALSE;
    ALTER TABLE users ADD COLUMN IF NOT EXISTS alpaca_account_id TEXT;
    ALTER TABLE users ADD COLUMN IF NOT EXISTS ibkr_account_id TEXT;
    -- Remove old CHECK constraint and allow new modes
    ALTER TABLE users DROP CONSTRAINT IF EXISTS users_account_mode_check;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- Seed allowed users (skip if they already exist)
INSERT INTO users (email, name, account_mode) VALUES
    ('samyak.rout@gmail.com', 'Samyak Rout', 'demo'),
    ('mahesh.sangawar@gmail.com', 'Mahesh Sangawar', 'demo')
ON CONFLICT (email) DO NOTHING;

-- ============================================================
-- MARKETS & STOCKS
-- ============================================================

CREATE TABLE IF NOT EXISTS markets (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    country TEXT NOT NULL,
    timezone TEXT NOT NULL,
    currency TEXT NOT NULL,
    currency_symbol TEXT NOT NULL DEFAULT '$',
    yfinance_suffix TEXT DEFAULT '',
    open_time TIME NOT NULL DEFAULT '09:30',
    close_time TIME NOT NULL DEFAULT '16:00',
    is_active BOOLEAN DEFAULT true
);

INSERT INTO markets (id, name, country, timezone, currency, currency_symbol, yfinance_suffix, open_time, close_time) VALUES
    ('NYSE',    'New York Stock Exchange',       'US', 'America/New_York',    'USD', '$',   '',    '09:30', '16:00'),
    ('NASDAQ',  'NASDAQ',                        'US', 'America/New_York',    'USD', '$',   '',    '09:30', '16:00'),
    ('NSE',     'National Stock Exchange',       'IN', 'Asia/Kolkata',        'INR', '₹',   '.NS', '09:15', '15:30'),
    ('BSE',     'Bombay Stock Exchange',         'IN', 'Asia/Kolkata',        'INR', '₹',   '.BO', '09:15', '15:30'),
    ('ASX',     'Australian Securities Exchange','AU', 'Australia/Sydney',    'AUD', 'A$',  '.AX', '10:00', '16:00'),
    ('LSE',     'London Stock Exchange',         'GB', 'Europe/London',       'GBP', '£',   '.L',  '08:00', '16:30'),
    ('TSE',     'Tokyo Stock Exchange',          'JP', 'Asia/Tokyo',          'JPY', '¥',   '.T',  '09:00', '15:00'),
    ('HKEX',    'Hong Kong Stock Exchange',      'HK', 'Asia/Hong_Kong',      'HKD', 'HK$', '.HK', '09:30', '16:00'),
    ('TSX',     'Toronto Stock Exchange',        'CA', 'America/Toronto',     'CAD', 'C$',  '.TO', '09:30', '16:00'),
    ('XETRA',   'Frankfurt Stock Exchange',      'DE', 'Europe/Berlin',       'EUR', '€',   '.DE', '09:00', '17:30'),
    ('SGX',     'Singapore Exchange',            'SG', 'Asia/Singapore',      'SGD', 'S$',  '.SI', '09:00', '17:00'),
    ('KRX',     'Korea Exchange',                'KR', 'Asia/Seoul',          'KRW', '₩',   '.KS', '09:00', '15:30')
ON CONFLICT (id) DO UPDATE SET
    name            = EXCLUDED.name,
    country         = EXCLUDED.country,
    timezone        = EXCLUDED.timezone,
    currency        = EXCLUDED.currency,
    currency_symbol = EXCLUDED.currency_symbol,
    yfinance_suffix = EXCLUDED.yfinance_suffix,
    open_time       = EXCLUDED.open_time,
    close_time      = EXCLUDED.close_time;

CREATE TABLE IF NOT EXISTS stocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol TEXT NOT NULL,
    name TEXT,
    market_id TEXT NOT NULL REFERENCES markets(id),
    sector TEXT,
    industry TEXT,
    yfinance_ticker TEXT NOT NULL,
    market_cap BIGINT,
    is_active BOOLEAN DEFAULT true,
    last_synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(symbol, market_id)
);

-- Seed popular stocks across all supported markets (upsert)
INSERT INTO stocks (symbol, name, market_id, sector, yfinance_ticker) VALUES
    -- US — NASDAQ
    ('AAPL',       'Apple Inc.',                    'NASDAQ', 'Technology',       'AAPL'),
    ('MSFT',       'Microsoft Corporation',         'NASDAQ', 'Technology',       'MSFT'),
    ('GOOGL',      'Alphabet Inc.',                 'NASDAQ', 'Technology',       'GOOGL'),
    ('AMZN',       'Amazon.com Inc.',               'NASDAQ', 'Consumer Cyclical','AMZN'),
    ('NVDA',       'NVIDIA Corporation',            'NASDAQ', 'Technology',       'NVDA'),
    ('TSLA',       'Tesla Inc.',                    'NASDAQ', 'Consumer Cyclical','TSLA'),
    ('META',       'Meta Platforms Inc.',            'NASDAQ', 'Technology',       'META'),
    ('NFLX',       'Netflix Inc.',                  'NASDAQ', 'Communication',    'NFLX'),
    ('AMD',        'Advanced Micro Devices',        'NASDAQ', 'Technology',       'AMD'),
    ('INTC',       'Intel Corporation',             'NASDAQ', 'Technology',       'INTC'),
    ('AVGO',       'Broadcom Inc.',                 'NASDAQ', 'Technology',       'AVGO'),
    ('COST',       'Costco Wholesale Corp.',        'NASDAQ', 'Consumer Staples', 'COST'),
    -- US — NYSE
    ('JPM',        'JPMorgan Chase & Co.',          'NYSE',   'Financial',        'JPM'),
    ('V',          'Visa Inc.',                     'NYSE',   'Financial',        'V'),
    ('JNJ',        'Johnson & Johnson',             'NYSE',   'Healthcare',       'JNJ'),
    ('WMT',        'Walmart Inc.',                  'NYSE',   'Consumer Staples', 'WMT'),
    ('UNH',        'UnitedHealth Group',            'NYSE',   'Healthcare',       'UNH'),
    ('MA',         'Mastercard Inc.',               'NYSE',   'Financial',        'MA'),
    ('BAC',        'Bank of America Corp.',         'NYSE',   'Financial',        'BAC'),
    ('DIS',        'The Walt Disney Company',       'NYSE',   'Communication',    'DIS'),
    ('KO',         'The Coca-Cola Company',         'NYSE',   'Consumer Staples', 'KO'),
    ('PFE',        'Pfizer Inc.',                   'NYSE',   'Healthcare',       'PFE'),
    -- India — NSE
    ('TCS',        'Tata Consultancy Services',     'NSE',    'Technology',       'TCS.NS'),
    ('RELIANCE',   'Reliance Industries',           'NSE',    'Energy',           'RELIANCE.NS'),
    ('INFY',       'Infosys Limited',               'NSE',    'Technology',       'INFY.NS'),
    ('HDFCBANK',   'HDFC Bank Limited',             'NSE',    'Financial',        'HDFCBANK.NS'),
    ('ITC',        'ITC Limited',                   'NSE',    'Consumer Staples', 'ITC.NS'),
    ('WIPRO',      'Wipro Limited',                 'NSE',    'Technology',       'WIPRO.NS'),
    ('BAJFINANCE', 'Bajaj Finance Limited',         'NSE',    'Financial',        'BAJFINANCE.NS'),
    ('SBIN',       'State Bank of India',           'NSE',    'Financial',        'SBIN.NS'),
    ('HCLTECH',    'HCL Technologies',              'NSE',    'Technology',       'HCLTECH.NS'),
    ('TATAMOTORS', 'Tata Motors Limited',           'NSE',    'Consumer Cyclical','TATAMOTORS.NS'),
    ('LT',         'Larsen & Toubro',               'NSE',    'Industrials',      'LT.NS'),
    ('ICICIBANK',  'ICICI Bank Limited',            'NSE',    'Financial',        'ICICIBANK.NS'),
    ('KOTAKBANK',  'Kotak Mahindra Bank',           'NSE',    'Financial',        'KOTAKBANK.NS'),
    ('SUNPHARMA',  'Sun Pharmaceutical',            'NSE',    'Healthcare',       'SUNPHARMA.NS'),
    ('BHARTIARTL', 'Bharti Airtel Limited',         'NSE',    'Communication',    'BHARTIARTL.NS'),
    ('ASIANPAINT', 'Asian Paints Limited',          'NSE',    'Materials',        'ASIANPAINT.NS'),
    ('MARUTI',     'Maruti Suzuki India',           'NSE',    'Consumer Cyclical','MARUTI.NS'),
    ('TITAN',      'Titan Company Limited',         'NSE',    'Consumer Cyclical','TITAN.NS'),
    ('ADANIENT',   'Adani Enterprises',             'NSE',    'Industrials',      'ADANIENT.NS'),
    -- Australia — ASX
    ('CBA',        'Commonwealth Bank',             'ASX',    'Financial',        'CBA.AX'),
    ('BHP',        'BHP Group Limited',             'ASX',    'Materials',        'BHP.AX'),
    ('CSL',        'CSL Limited',                   'ASX',    'Healthcare',       'CSL.AX'),
    ('NAB',        'National Australia Bank',       'ASX',    'Financial',        'NAB.AX'),
    ('WBC',        'Westpac Banking Corp',          'ASX',    'Financial',        'WBC.AX'),
    ('ANZ',        'ANZ Group Holdings',            'ASX',    'Financial',        'ANZ.AX'),
    ('WDS',        'Woodside Energy Group',         'ASX',    'Energy',           'WDS.AX'),
    ('FMG',        'Fortescue Metals Group',        'ASX',    'Materials',        'FMG.AX'),
    ('WES',        'Wesfarmers Limited',            'ASX',    'Consumer Staples', 'WES.AX'),
    ('TLS',        'Telstra Group Limited',         'ASX',    'Communication',    'TLS.AX'),
    ('RIO',        'Rio Tinto Limited',             'ASX',    'Materials',        'RIO.AX'),
    -- UK — LSE
    ('SHEL',       'Shell plc',                     'LSE',    'Energy',           'SHEL.L'),
    ('AZN',        'AstraZeneca plc',               'LSE',    'Healthcare',       'AZN.L'),
    ('HSBA',       'HSBC Holdings plc',             'LSE',    'Financial',        'HSBA.L'),
    ('ULVR',       'Unilever plc',                  'LSE',    'Consumer Staples', 'ULVR.L'),
    ('BP',         'BP plc',                        'LSE',    'Energy',           'BP.L'),
    ('GSK',        'GSK plc',                       'LSE',    'Healthcare',       'GSK.L'),
    ('RIO',        'Rio Tinto plc',                 'LSE',    'Materials',        'RIO.L'),
    ('BARC',       'Barclays plc',                  'LSE',    'Financial',        'BARC.L'),
    -- Japan — TSE
    ('7203',       'Toyota Motor Corp',             'TSE',    'Consumer Cyclical','7203.T'),
    ('6758',       'Sony Group Corp',               'TSE',    'Technology',       '6758.T'),
    ('6861',       'Keyence Corporation',           'TSE',    'Technology',       '6861.T'),
    ('9984',       'SoftBank Group Corp',           'TSE',    'Technology',       '9984.T'),
    ('6902',       'DENSO Corporation',             'TSE',    'Consumer Cyclical','6902.T'),
    ('8306',       'Mitsubishi UFJ Financial',      'TSE',    'Financial',        '8306.T'),
    -- Hong Kong — HKEX
    ('0700',       'Tencent Holdings',              'HKEX',   'Technology',       '0700.HK'),
    ('9988',       'Alibaba Group Holding',         'HKEX',   'Technology',       '9988.HK'),
    ('0005',       'HSBC Holdings',                 'HKEX',   'Financial',        '0005.HK'),
    ('1299',       'AIA Group Limited',             'HKEX',   'Financial',        '1299.HK'),
    -- Canada — TSX
    ('RY',         'Royal Bank of Canada',          'TSX',    'Financial',        'RY.TO'),
    ('TD',         'Toronto-Dominion Bank',         'TSX',    'Financial',        'TD.TO'),
    ('SHOP',       'Shopify Inc.',                  'TSX',    'Technology',       'SHOP.TO'),
    ('ENB',        'Enbridge Inc.',                 'TSX',    'Energy',           'ENB.TO'),
    -- Germany — XETRA
    ('SAP',        'SAP SE',                        'XETRA',  'Technology',       'SAP.DE'),
    ('SIE',        'Siemens AG',                    'XETRA',  'Industrials',      'SIE.DE'),
    ('ALV',        'Allianz SE',                    'XETRA',  'Financial',        'ALV.DE'),
    -- Singapore — SGX
    ('D05',        'DBS Group Holdings',            'SGX',    'Financial',        'D05.SI'),
    ('O39',        'OCBC Bank',                     'SGX',    'Financial',        'O39.SI'),
    -- South Korea — KRX
    ('005930',     'Samsung Electronics',           'KRX',    'Technology',       '005930.KS'),
    ('000660',     'SK Hynix Inc.',                 'KRX',    'Technology',       '000660.KS')
ON CONFLICT (symbol, market_id) DO UPDATE SET
    name            = EXCLUDED.name,
    sector          = EXCLUDED.sector,
    yfinance_ticker = EXCLUDED.yfinance_ticker;

-- ============================================================
-- STOCK PRICES (TimescaleDB Hypertable)
-- ============================================================

CREATE TABLE IF NOT EXISTS stock_prices (
    time TIMESTAMPTZ NOT NULL,
    stock_id UUID NOT NULL REFERENCES stocks(id),
    open NUMERIC(14,4),
    high NUMERIC(14,4),
    low NUMERIC(14,4),
    close NUMERIC(14,4),
    volume BIGINT,
    interval TEXT DEFAULT '1d'
);

-- Convert to hypertable only if TimescaleDB is available
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.hypertables
        WHERE hypertable_name = 'stock_prices'
    ) THEN
        PERFORM create_hypertable('stock_prices', 'time');
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TimescaleDB not available, skipping hypertable creation';
END
$$;

-- Indexes (work on both standard PostgreSQL and TimescaleDB)
CREATE INDEX IF NOT EXISTS idx_stock_prices_stock_id  ON stock_prices (stock_id, time DESC);
CREATE INDEX IF NOT EXISTS idx_stock_prices_interval  ON stock_prices (stock_id, interval, time DESC);

-- Compression — TimescaleDB only
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.compression_settings
        WHERE hypertable_name = 'stock_prices'
    ) THEN
        ALTER TABLE stock_prices SET (
            timescaledb.compress,
            timescaledb.compress_segmentby = 'stock_id,interval'
        );
        PERFORM add_compression_policy('stock_prices', INTERVAL '30 days');
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TimescaleDB compression not available, skipping';
END
$$;

-- Continuous aggregate — TimescaleDB only
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.continuous_aggregates
        WHERE view_name = 'stock_prices_daily'
    ) THEN
        EXECUTE $agg$
            CREATE MATERIALIZED VIEW stock_prices_daily
            WITH (timescaledb.continuous) AS
            SELECT
                time_bucket('1 day', time) AS bucket,
                stock_id,
                first(open, time) AS open,
                max(high) AS high,
                min(low) AS low,
                last(close, time) AS close,
                sum(volume) AS volume
            FROM stock_prices
            WHERE interval = '1h'
            GROUP BY bucket, stock_id
            WITH NO DATA
        $agg$;

        PERFORM add_continuous_aggregate_policy('stock_prices_daily',
            start_offset  => INTERVAL '3 days',
            end_offset    => INTERVAL '1 hour',
            schedule_interval => INTERVAL '1 hour');
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'TimescaleDB continuous aggregates not available, skipping';
END
$$;

-- ============================================================
-- PORTFOLIOS & TRADING
-- ============================================================

CREATE TABLE IF NOT EXISTS portfolios (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    mode TEXT DEFAULT 'demo' CHECK (mode IN ('demo', 'actual')),
    initial_balance NUMERIC(14,2) DEFAULT 100000.00,
    cash_balance NUMERIC(14,2) DEFAULT 100000.00,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS holdings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    portfolio_id UUID NOT NULL REFERENCES portfolios(id) ON DELETE CASCADE,
    stock_id UUID NOT NULL REFERENCES stocks(id),
    quantity NUMERIC(14,4) NOT NULL,
    avg_buy_price NUMERIC(14,4) NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(portfolio_id, stock_id)
);

CREATE TABLE IF NOT EXISTS trades (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    portfolio_id UUID NOT NULL REFERENCES portfolios(id) ON DELETE CASCADE,
    stock_id UUID NOT NULL REFERENCES stocks(id),
    side TEXT NOT NULL CHECK (side IN ('buy', 'sell')),
    order_type TEXT DEFAULT 'market' CHECK (order_type IN ('market', 'limit', 'stop_loss')),
    quantity NUMERIC(14,4) NOT NULL,
    price NUMERIC(14,4) NOT NULL,
    limit_price NUMERIC(14,4),
    total_amount NUMERIC(14,2) NOT NULL,
    currency TEXT NOT NULL DEFAULT 'USD',
    status TEXT DEFAULT 'executed' CHECK (status IN ('pending', 'executed', 'cancelled', 'failed')),
    agent_run_id TEXT,
    notes TEXT,
    executed_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_trades_portfolio ON trades (portfolio_id, executed_at DESC);

-- Seed default demo portfolios for allowed users (skip if already exist)
INSERT INTO portfolios (user_id, name, mode, initial_balance, cash_balance)
SELECT u.id, 'My Demo Portfolio', 'demo', 100000.00, 100000.00
FROM users u
WHERE u.email IN ('samyak.rout@gmail.com', 'mahesh.sangawar@gmail.com')
  AND NOT EXISTS (
      SELECT 1 FROM portfolios p WHERE p.user_id = u.id AND p.name = 'My Demo Portfolio'
  );

-- ============================================================
-- WATCHLISTS
-- ============================================================

CREATE TABLE IF NOT EXISTS watchlists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT DEFAULT 'Default',
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS watchlist_items (
    watchlist_id UUID NOT NULL REFERENCES watchlists(id) ON DELETE CASCADE,
    stock_id UUID NOT NULL REFERENCES stocks(id),
    added_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (watchlist_id, stock_id)
);

-- Seed default watchlists with popular stocks for each user
DO $$
DECLARE
    v_user_id UUID;
    v_wl_id UUID;
BEGIN
    FOR v_user_id IN
        SELECT id FROM users WHERE email IN ('samyak.rout@gmail.com', 'mahesh.sangawar@gmail.com')
    LOOP
        -- Create default watchlist if not exists
        SELECT id INTO v_wl_id FROM watchlists WHERE user_id = v_user_id AND name = 'Default';
        IF v_wl_id IS NULL THEN
            INSERT INTO watchlists (user_id, name) VALUES (v_user_id, 'Default') RETURNING id INTO v_wl_id;

            -- Seed with top stocks from each market
            INSERT INTO watchlist_items (watchlist_id, stock_id)
            SELECT v_wl_id, s.id
            FROM stocks s
            WHERE (s.symbol, s.market_id) IN (
                ('AAPL',     'NASDAQ'),
                ('MSFT',     'NASDAQ'),
                ('NVDA',     'NASDAQ'),
                ('GOOGL',    'NASDAQ'),
                ('TSLA',     'NASDAQ'),
                ('RELIANCE', 'NSE'),
                ('TCS',      'NSE'),
                ('HDFCBANK', 'NSE'),
                ('CBA',      'ASX'),
                ('BHP',      'ASX')
            )
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
END
$$;

-- ============================================================
-- AI AGENTS
-- ============================================================

CREATE TABLE IF NOT EXISTS agent_conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    agent_type TEXT NOT NULL,
    run_id TEXT NOT NULL,
    input_data JSONB,
    output_data JSONB,
    model_used TEXT,
    tokens_used INTEGER,
    duration_ms INTEGER,
    status TEXT DEFAULT 'completed' CHECK (status IN ('running', 'completed', 'failed')),
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agent_conversations_user ON agent_conversations (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_conversations_run  ON agent_conversations (run_id);

CREATE TABLE IF NOT EXISTS research_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    stock_id UUID NOT NULL REFERENCES stocks(id),
    report_type TEXT NOT NULL CHECK (report_type IN ('technical', 'fundamental', 'sentiment', 'comprehensive')),
    recommendation TEXT CHECK (recommendation IN ('strong_buy', 'buy', 'hold', 'sell', 'strong_sell')),
    confidence_score NUMERIC(3,2),
    summary TEXT,
    technical_data JSONB,
    fundamental_data JSONB,
    sentiment_data JSONB,
    full_report JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_research_reports_user  ON research_reports (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_research_reports_stock ON research_reports (stock_id, created_at DESC);

-- ============================================================
-- AGENT DECISION MEMORY (pgvector situation-similarity retrieval)
-- ============================================================
-- Persists a compact "situation summary" + 1536-dim embedding for every
-- trading-graph run, so the next run on the same user can retrieve
-- semantically similar past decisions and inject them into the bull/
-- bear/PM prompts (matching the layered-memory pattern in the
-- TauricResearch/TradingAgents paper).
--
-- The vector(1536) column matches OpenAI's text-embedding-3-small.
-- HNSW is preferred over IVFFLAT for read-heavy access at our scale.
-- The DO block guards the column add when pgvector isn't installed
-- so the bootstrap stays idempotent on any image (the cluster image
-- on prod has pgvector; some dev images may not).

CREATE TABLE IF NOT EXISTS agent_decision_memory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    research_report_id UUID REFERENCES research_reports(id) ON DELETE SET NULL,
    ticker TEXT NOT NULL,
    run_date DATE NOT NULL,
    rating TEXT,
    trader_action TEXT,
    position_size_pct NUMERIC(5,4),
    confidence NUMERIC(3,2),
    persona TEXT DEFAULT 'balanced',
    situation_summary TEXT NOT NULL,
    raw_return NUMERIC(8,4),
    alpha_return NUMERIC(8,4),
    holding_days INTEGER,
    reflection TEXT,
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
        -- One column per embedding provider so the dim always matches:
        --   gemini text-embedding-004   = 768
        --   voyage voyage-3.5           = 1024
        --   openai text-embedding-3-small = 1536 (kept under the original
        --     unsuffixed name for backward compat with previously-written rows)
        EXECUTE 'ALTER TABLE agent_decision_memory '
                'ADD COLUMN IF NOT EXISTS situation_embedding vector(1536)';
        EXECUTE 'ALTER TABLE agent_decision_memory '
                'ADD COLUMN IF NOT EXISTS situation_embedding_gemini vector(768)';
        EXECUTE 'ALTER TABLE agent_decision_memory '
                'ADD COLUMN IF NOT EXISTS situation_embedding_voyage vector(1024)';
        -- HNSW cosine indexes per column. Fast on empty / small tables.
        IF NOT EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE schemaname = current_schema()
              AND indexname = 'idx_agent_decision_memory_embedding'
        ) THEN
            EXECUTE 'CREATE INDEX idx_agent_decision_memory_embedding '
                    'ON agent_decision_memory '
                    'USING hnsw (situation_embedding vector_cosine_ops)';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE schemaname = current_schema()
              AND indexname = 'idx_agent_decision_memory_embedding_gemini'
        ) THEN
            EXECUTE 'CREATE INDEX idx_agent_decision_memory_embedding_gemini '
                    'ON agent_decision_memory '
                    'USING hnsw (situation_embedding_gemini vector_cosine_ops)';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE schemaname = current_schema()
              AND indexname = 'idx_agent_decision_memory_embedding_voyage'
        ) THEN
            EXECUTE 'CREATE INDEX idx_agent_decision_memory_embedding_voyage '
                    'ON agent_decision_memory '
                    'USING hnsw (situation_embedding_voyage vector_cosine_ops)';
        END IF;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_agent_decision_memory_user_ticker
    ON agent_decision_memory (user_id, ticker, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_decision_memory_user_recent
    ON agent_decision_memory (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_decision_memory_resolved
    ON agent_decision_memory (resolved_at)
    WHERE resolved_at IS NULL;

-- Runtime app user must be able to read/write the new table.
-- Schema bootstrap runs as `postgres`; without explicit GRANT the
-- runtime role (`stockpilot`) gets PermissionDenied which poisons
-- the SQLAlchemy session. Idempotent — safe to re-run.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stockpilot') THEN
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON agent_decision_memory TO stockpilot';
    END IF;
END $$;

-- ============================================================
-- SUPERINVESTOR PORTFOLIOS (13F-derived holdings of famous investors)
-- ============================================================
-- Curated list of currently-active 13F filers + a few legacy persona-only
-- entries (Munger / Lynch). Refreshed weekly from dataroma.com (or SEC EDGAR
-- 13F-HR XML as a fallback) by tasks.superinvestors. Holdings are stamped
-- with the as-of date of the filing they came from — DO NOT present this
-- as live-portfolio data; it lags 45 days minimum.

CREATE TABLE IF NOT EXISTS superinvestors (
    slug TEXT PRIMARY KEY,                       -- e.g. "buffett", "ackman"
    name TEXT NOT NULL,                          -- "Warren Buffett"
    firm TEXT NOT NULL,                          -- "Berkshire Hathaway"
    tier TEXT NOT NULL DEFAULT 'value',          -- value|activist|allocator|legacy
    style_tags TEXT[] DEFAULT '{}',
    bio TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','legacy','paused')),
    dataroma_id TEXT,                            -- e.g. "BRK"
    cik TEXT,                                    -- SEC CIK for EDGAR fallback
    last_filing_date DATE,
    last_synced_at TIMESTAMPTZ,
    sort_order INTEGER NOT NULL DEFAULT 100,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS superinvestor_holdings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    investor_slug TEXT NOT NULL REFERENCES superinvestors(slug) ON DELETE CASCADE,
    ticker TEXT NOT NULL,
    company TEXT,
    weight_pct NUMERIC(6,3),
    value_usd NUMERIC(20,2),
    shares NUMERIC(20,2),
    prior_shares NUMERIC(20,2),
    change_type TEXT CHECK (change_type IN ('NEW','ADD','REDUCE','EXIT','HOLD')),
    as_of_date DATE NOT NULL,
    filing_date DATE,
    filing_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (investor_slug, ticker, as_of_date)
);

CREATE INDEX IF NOT EXISTS idx_superinvestor_holdings_investor_asof
    ON superinvestor_holdings (investor_slug, as_of_date DESC);
CREATE INDEX IF NOT EXISTS idx_superinvestor_holdings_ticker
    ON superinvestor_holdings (ticker);

-- Runtime app user perms (idempotent).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stockpilot') THEN
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON superinvestors TO stockpilot';
        EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON superinvestor_holdings TO stockpilot';
    END IF;
END $$;

-- Curated investor seed list. Pinned via UPSERT so future edits to the spec
-- (e.g. style_tags, sort_order) propagate next bootstrap run.
-- dataroma_id values verified against dataroma.com/m/managers.php on
-- 2026-05-03. Three investors are NOT in dataroma's index — Stanley
-- Druckenmiller (Duquesne is a private family office), Joel Greenblatt
-- (Gotham not listed), and Charlie Munger (Daily Journal isn't tracked
-- separately) — leave dataroma_id NULL so the scraper skips them.
INSERT INTO superinvestors (slug, name, firm, tier, status, sort_order, dataroma_id, style_tags)
VALUES
    ('buffett',      'Warren Buffett',     'Berkshire Hathaway',          'value',     'active', 10,  'BRK',     ARRAY['quality','concentrated','owner-mindset']),
    ('druckenmiller','Stanley Druckenmiller','Duquesne Family Office',    'value',     'active', 20,  NULL,      ARRAY['macro','high-conviction']),
    ('klarman',      'Seth Klarman',       'Baupost Group',               'value',     'active', 30,  'BAUPOST', ARRAY['deep-value','contrarian']),
    ('lilu',         'Li Lu',              'Himalaya Capital',            'value',     'active', 40,  'HC',      ARRAY['quality','concentrated']),
    ('pabrai',       'Mohnish Pabrai',     'Pabrai Investment Funds',     'value',     'active', 50,  'PI',      ARRAY['cloned-buffett','high-conviction']),
    ('spier',        'Guy Spier',          'Aquamarine Capital',          'value',     'active', 60,  'aq',      ARRAY['buffett-style']),
    ('terrysmith',   'Terry Smith',        'Fundsmith',                   'value',     'active', 70,  'FS',      ARRAY['quality-compounders','uk']),
    ('billmiller',   'Bill Miller',        'Miller Value Partners',       'value',     'active', 80,  'LMM',     ARRAY['contrarian','long-term']),
    ('kantesaria',   'Dev Kantesaria',     'Valley Forge Capital',        'value',     'active', 90,  'VFC',     ARRAY['hyper-concentrated','quality']),
    ('gayner',       'Tom Gayner',         'Markel Group',                'value',     'active', 100, 'MKL',     ARRAY['allocator']),
    ('ackman',       'Bill Ackman',        'Pershing Square Capital',     'activist',  'active', 110, 'psc',     ARRAY['activist','concentrated']),
    ('tepper',       'David Tepper',       'Appaloosa Management',        'activist',  'active', 120, 'AM',      ARRAY['distressed','macro']),
    ('hohn',         'Chris Hohn',         'TCI Fund Management',         'activist',  'active', 130, 'TCI',     ARRAY['activist','long-term']),
    ('icahn',        'Carl Icahn',         'Icahn Enterprises',           'activist',  'active', 140, 'ic',      ARRAY['activist']),
    ('loeb',         'Dan Loeb',           'Third Point',                 'activist',  'active', 150, 'TP',      ARRAY['event-driven']),
    ('peltz',        'Nelson Peltz',       'Trian Fund Management',       'activist',  'active', 160, 'TF',      ARRAY['activist']),
    ('marks',        'Howard Marks',       'Oaktree Capital',             'allocator', 'active', 170, 'oc',      ARRAY['credit-aware']),
    ('greenblatt',   'Joel Greenblatt',    'Gotham Asset Management',     'allocator', 'active', 180, NULL,      ARRAY['magic-formula','special-situations']),
    ('munger',       'Charlie Munger',     'Daily Journal Corp',          'legacy',    'legacy', 990, NULL,      ARRAY['historical','run-by-successor-since-q4-2023']),
    ('lynch',        'Peter Lynch',        'Magellan Fund (retired 1990)','legacy',    'legacy', 999, NULL,      ARRAY['historical','persona-only'])
ON CONFLICT (slug) DO UPDATE SET
    name = EXCLUDED.name,
    firm = EXCLUDED.firm,
    tier = EXCLUDED.tier,
    status = EXCLUDED.status,
    sort_order = EXCLUDED.sort_order,
    dataroma_id = EXCLUDED.dataroma_id,
    style_tags = EXCLUDED.style_tags;

-- ============================================================
-- ALERTS & NOTIFICATIONS
-- ============================================================

CREATE TABLE IF NOT EXISTS price_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    stock_id UUID NOT NULL REFERENCES stocks(id),
    condition TEXT NOT NULL CHECK (condition IN ('above', 'below', 'percent_change')),
    target_price NUMERIC(14,4),
    target_percent NUMERIC(6,2),
    is_triggered BOOLEAN DEFAULT false,
    triggered_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_price_alerts_user ON price_alerts (user_id, is_triggered);

-- ============================================================
-- WEEKLY PREDICTIONS
-- ============================================================

CREATE TABLE IF NOT EXISTS weekly_predictions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    week_start TIMESTAMPTZ NOT NULL,
    week_end TIMESTAMPTZ NOT NULL,
    market_id TEXT NOT NULL,
    top_performers JSONB NOT NULL DEFAULT '[]',
    undervalued JSONB NOT NULL DEFAULT '[]',
    market_summary TEXT,
    risk_assessment TEXT,
    full_analysis JSONB,
    model_used TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_weekly_predictions_week ON weekly_predictions (week_start, market_id);

-- ============================================================
-- SCHEMA VERSION TRACKING
-- ============================================================

CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    description TEXT,
    applied_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO schema_migrations (version, description) VALUES
    ('001', 'Initial schema: users, markets, stocks, prices, portfolios, trades, watchlists, agents, alerts')
ON CONFLICT (version) DO NOTHING;

INSERT INTO schema_migrations (version, description) VALUES
    ('002', 'Add weekly_predictions table for AI prediction reports')
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- USER BROKER COLUMNS (v003)
-- ============================================================

DO $$ BEGIN
    ALTER TABLE users ADD COLUMN IF NOT EXISTS polymarket_wallet_address TEXT;
    ALTER TABLE users ADD COLUMN IF NOT EXISTS polymarket_funder_address TEXT;
    ALTER TABLE users ADD COLUMN IF NOT EXISTS polymarket_configured BOOLEAN DEFAULT FALSE;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- ============================================================
-- DCA STRATEGY (v003)
-- ============================================================

CREATE TABLE IF NOT EXISTS dca_strategies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    portfolio_id UUID NOT NULL REFERENCES portfolios(id) ON DELETE CASCADE,
    name TEXT DEFAULT 'Monthly Value Investor',
    monthly_budget NUMERIC(14,2) DEFAULT 1000.00,
    max_picks_per_month INTEGER DEFAULT 5,
    min_picks_per_month INTEGER DEFAULT 3,
    risk_tolerance TEXT DEFAULT 'moderate',
    market_filter TEXT DEFAULT 'US',
    strategy_type TEXT DEFAULT 'value_growth',
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dca_executions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_id UUID NOT NULL REFERENCES dca_strategies(id) ON DELETE CASCADE,
    month TEXT NOT NULL,
    status TEXT DEFAULT 'pending',
    budget_used NUMERIC(14,2) DEFAULT 0,
    picks JSONB NOT NULL DEFAULT '[]',
    screening_summary TEXT,
    market_regime TEXT,
    risk_assessment TEXT,
    candidates_analyzed INTEGER DEFAULT 0,
    total_candidates INTEGER DEFAULT 0,
    portfolio_snapshot JSONB,
    performance_since JSONB,
    error_message TEXT,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE (strategy_id, month)
);

CREATE INDEX IF NOT EXISTS idx_dca_executions_month ON dca_executions (month);

-- ============================================================
-- POLYMARKET PREDICTION MARKETS (v003)
-- ============================================================

CREATE TABLE IF NOT EXISTS polymarket_strategies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT DEFAULT 'Polymarket AI Bettor',
    bankroll_usdc NUMERIC(14,2) DEFAULT 130.00,
    max_bets_per_day INTEGER DEFAULT 7,
    max_concurrent_positions INTEGER DEFAULT 10,
    risk_level TEXT DEFAULT 'moderate',
    min_edge_threshold NUMERIC(4,3) DEFAULT 0.020,  -- 2% min edge — small edges count
    kelly_fraction NUMERIC(3,2) DEFAULT 0.25,
    max_single_bet_pct NUMERIC(3,2) DEFAULT 0.12,   -- 12% max per bet
    min_reserve_pct NUMERIC(3,2) DEFAULT 0.15,      -- 15% reserve
    auto_execute BOOLEAN DEFAULT true,              -- fully autonomous by default
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS polymarket_bets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_id UUID NOT NULL REFERENCES polymarket_strategies(id) ON DELETE CASCADE,
    condition_id TEXT NOT NULL,
    market_question TEXT,
    market_slug TEXT,
    outcome TEXT NOT NULL,
    token_id TEXT NOT NULL,
    amount_usdc NUMERIC(14,2) NOT NULL,
    price NUMERIC(5,4) NOT NULL,
    shares NUMERIC(14,4),
    order_type TEXT DEFAULT 'GTC',
    order_id TEXT,
    estimated_prob NUMERIC(5,4),
    edge NUMERIC(5,4),
    kelly_bet_size NUMERIC(14,2),
    reasoning TEXT,
    status TEXT DEFAULT 'pending_approval',
    pnl_usdc NUMERIC(14,2),
    market_end_date TIMESTAMPTZ,
    liquidity NUMERIC(14,2),
    volume_24h NUMERIC(14,2),
    scan_metadata JSONB,
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_polymarket_bets_status ON polymarket_bets (strategy_id, status);

INSERT INTO schema_migrations (version, description) VALUES
    ('003', 'Add DCA strategy, Polymarket integration, user polymarket columns')
ON CONFLICT (version) DO NOTHING;

-- ============================================================
-- DONE
-- ============================================================
-- This script is fully idempotent. Running it multiple times
-- will not duplicate data, fail on existing objects, or alter
-- user-created data. Only seed/reference data is upserted.
