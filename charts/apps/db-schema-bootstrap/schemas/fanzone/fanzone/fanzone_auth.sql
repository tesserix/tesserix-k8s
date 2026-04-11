-- =============================================================================
-- fanzone_auth database schema
-- Idempotent — safe to re-run (CREATE TABLE IF NOT EXISTS, ON CONFLICT DO NOTHING)
-- =============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================================================
-- 1. USERS — core user accounts
-- =============================================================================
CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username        VARCHAR(255) UNIQUE,
    email           VARCHAR(255) UNIQUE,
    phone           VARCHAR(20) UNIQUE,
    password_hash   VARCHAR(255),
    name            VARCHAR(255) NOT NULL,
    avatar_url      TEXT,
    provider        VARCHAR(50),
    provider_id     VARCHAR(255),
    email_verified  BOOLEAN DEFAULT FALSE,
    phone_verified  BOOLEAN DEFAULT FALSE,
    role            VARCHAR(50) DEFAULT 'user' CHECK (role IN ('user', 'moderator', 'admin', 'super_admin')),
    is_active       BOOLEAN DEFAULT TRUE,
    login_count     INTEGER DEFAULT 0,
    signup_source   VARCHAR(50),
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_login_at   TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(LOWER(email));
CREATE INDEX IF NOT EXISTS idx_users_username ON users(LOWER(username));
CREATE INDEX IF NOT EXISTS idx_users_phone ON users(phone);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);

-- =============================================================================
-- 2. USER_PROVIDERS — multi-provider authentication mapping
-- =============================================================================
CREATE TABLE IF NOT EXISTS user_providers (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider    VARCHAR(50) NOT NULL,
    provider_id VARCHAR(255) NOT NULL,
    created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(provider, provider_id)
);

CREATE INDEX IF NOT EXISTS idx_user_providers_user_id ON user_providers(user_id);
CREATE INDEX IF NOT EXISTS idx_user_providers_provider ON user_providers(provider, provider_id);

-- =============================================================================
-- 3. REFRESH_TOKENS — JWT refresh token management with revocation
-- =============================================================================
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  VARCHAR(255) NOT NULL UNIQUE,
    expires_at  TIMESTAMP WITH TIME ZONE NOT NULL,
    revoked     BOOLEAN DEFAULT FALSE,
    created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token_hash ON refresh_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_expires_at ON refresh_tokens(expires_at);

-- =============================================================================
-- 4. OAUTH_STATES — OAuth flow CSRF state tokens (10 min expiry)
-- =============================================================================
CREATE TABLE IF NOT EXISTS oauth_states (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    state       VARCHAR(255) UNIQUE NOT NULL,
    provider    VARCHAR(50) NOT NULL,
    redirect_url TEXT,
    expires_at  TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_oauth_states_state ON oauth_states(state);
CREATE INDEX IF NOT EXISTS idx_oauth_states_expires_at ON oauth_states(expires_at);

-- =============================================================================
-- 5. SUPER_ADMIN_EMAILS — whitelist for automatic super_admin promotion
-- =============================================================================
CREATE TABLE IF NOT EXISTS super_admin_emails (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       VARCHAR(255) NOT NULL UNIQUE,
    added_by    UUID REFERENCES users(id) ON DELETE SET NULL,
    note        TEXT,
    is_active   BOOLEAN DEFAULT TRUE,
    created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_super_admin_emails_email ON super_admin_emails(LOWER(email));
CREATE INDEX IF NOT EXISTS idx_super_admin_emails_is_active ON super_admin_emails(is_active);

-- =============================================================================
-- 6. USER_SESSIONS — login session tracking with device info
-- =============================================================================
CREATE TABLE IF NOT EXISTS user_sessions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ip_address  INET,
    user_agent  TEXT,
    device_info JSONB,
    created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    expires_at  TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_user_sessions_user_id ON user_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_user_sessions_created_at ON user_sessions(created_at);

-- =============================================================================
-- 7. LOGIN_ATTEMPTS — auth attempt audit trail (success/failure)
-- =============================================================================
CREATE TABLE IF NOT EXISTS login_attempts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    method          VARCHAR(50) NOT NULL,
    success         BOOLEAN NOT NULL,
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
    visitor_id      VARCHAR(255),
    ip_address      INET,
    user_agent      TEXT,
    failure_reason  VARCHAR(255),
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_login_attempts_user_id ON login_attempts(user_id);
CREATE INDEX IF NOT EXISTS idx_login_attempts_method ON login_attempts(method);
CREATE INDEX IF NOT EXISTS idx_login_attempts_created_at ON login_attempts(created_at);
CREATE INDEX IF NOT EXISTS idx_login_attempts_visitor_id ON login_attempts(visitor_id);

-- =============================================================================
-- 8. SITE_VISITS — visitor tracking (authenticated + anonymous)
-- =============================================================================
CREATE TABLE IF NOT EXISTS site_visits (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    visitor_id      VARCHAR(255) NOT NULL,
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
    page_url        TEXT,
    referrer        TEXT,
    device_type     VARCHAR(50),
    user_agent      TEXT,
    ip_address      INET,
    session_start   BOOLEAN DEFAULT FALSE,
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_site_visits_visitor_id ON site_visits(visitor_id);
CREATE INDEX IF NOT EXISTS idx_site_visits_user_id ON site_visits(user_id);
CREATE INDEX IF NOT EXISTS idx_site_visits_created_at ON site_visits(created_at);
CREATE INDEX IF NOT EXISTS idx_site_visits_device_type ON site_visits(device_type);

-- =============================================================================
-- 9. USER_EVENTS — page view and custom event tracking
-- =============================================================================
CREATE TABLE IF NOT EXISTS user_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID REFERENCES users(id) ON DELETE SET NULL,
    event_type  VARCHAR(100) NOT NULL,
    event_name  VARCHAR(255),
    page_url    TEXT,
    metadata    JSONB,
    session_id  UUID,
    created_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_events_user_id ON user_events(user_id);
CREATE INDEX IF NOT EXISTS idx_user_events_event_type ON user_events(event_type);
CREATE INDEX IF NOT EXISTS idx_user_events_created_at ON user_events(created_at);

-- =============================================================================
-- 10. USER_POINTS — per-user point balances
-- =============================================================================
CREATE TABLE IF NOT EXISTS user_points (
    user_id      UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    balance      DOUBLE PRECISION NOT NULL DEFAULT 0,
    total_earned DOUBLE PRECISION NOT NULL DEFAULT 0,
    total_spent  DOUBLE PRECISION NOT NULL DEFAULT 0,
    level        INTEGER NOT NULL DEFAULT 1,
    created_at   TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================================
-- 11. USER_ROOM_POINTS — per-room point tracking
-- =============================================================================
CREATE TABLE IF NOT EXISTS user_room_points (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    room_id    VARCHAR(255) NOT NULL,
    points     DOUBLE PRECISION NOT NULL DEFAULT 0,
    messages   INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, room_id)
);

CREATE INDEX IF NOT EXISTS idx_user_room_points_room_id ON user_room_points(room_id);

-- =============================================================================
-- 12. POINTS_LEDGER — immutable point transaction log
-- =============================================================================
CREATE TABLE IF NOT EXISTS points_ledger (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount          DOUBLE PRECISION NOT NULL,
    balance         DOUBLE PRECISION NOT NULL,
    type            VARCHAR(50) NOT NULL,
    room_id         VARCHAR(255),
    description     TEXT,
    idempotency_key VARCHAR(255) UNIQUE,
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_points_ledger_user_id ON points_ledger(user_id);
CREATE INDEX IF NOT EXISTS idx_points_ledger_type ON points_ledger(type);
CREATE INDEX IF NOT EXISTS idx_points_ledger_created_at ON points_ledger(created_at);

-- =============================================================================
-- 13. POINT_CONFIG — admin-configurable point economy values
-- =============================================================================
CREATE TABLE IF NOT EXISTS point_config (
    key         VARCHAR(100) PRIMARY KEY,
    value       DOUBLE PRECISION NOT NULL,
    description TEXT,
    updated_at  TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Seed default point config values (skip if already exist)
INSERT INTO point_config (key, value, description) VALUES
    ('signup_bonus',       50,    'Points awarded on new user registration'),
    ('chat_message',       0.02,  'Points per chat message sent'),
    ('poll_correct',       2.50,  'Points for answering a poll correctly'),
    ('daily_login',        2.50,  'Points for daily login check-in'),
    ('streak_7d',          25,    'Bonus points for 7-day login streak'),
    ('streak_30d',         100,   'Bonus points for 30-day login streak'),
    ('streak_100d',        500,   'Bonus points for 100-day login streak'),
    ('streak_freeze_cost', 50,    'Points cost to freeze a streak'),
    ('game_perfect_bonus', 100,   'Bonus for perfect game score'),
    ('house_fee_per_bet',  0.75,  'House fee deducted per prediction bet')
ON CONFLICT (key) DO NOTHING;

-- =============================================================================
-- 14. SYSTEM_POINT_POOL — singleton row tracking the global point pool
-- =============================================================================
CREATE TABLE IF NOT EXISTS system_point_pool (
    id                INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    balance           DOUBLE PRECISION NOT NULL DEFAULT 100000000,
    total_distributed DOUBLE PRECISION NOT NULL DEFAULT 0,
    total_reclaimed   DOUBLE PRECISION NOT NULL DEFAULT 0,
    created_at        TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Seed the pool singleton if it doesn't exist (100M starting balance)
INSERT INTO system_point_pool (id, balance) VALUES (1, 100000000)
ON CONFLICT (id) DO NOTHING;

-- =============================================================================
-- 15. POOL_LEDGER — immutable pool transaction log
-- =============================================================================
CREATE TABLE IF NOT EXISTS pool_ledger (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    amount       DOUBLE PRECISION NOT NULL,
    balance      DOUBLE PRECISION NOT NULL,
    type         VARCHAR(50) NOT NULL,
    user_id      UUID REFERENCES users(id) ON DELETE SET NULL,
    description  TEXT,
    reference_id VARCHAR(255),
    created_at   TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_pool_ledger_type ON pool_ledger(type);
CREATE INDEX IF NOT EXISTS idx_pool_ledger_created_at ON pool_ledger(created_at);

-- =============================================================================
-- 16. POOL_HOURLY_SNAPSHOTS — hourly pool state snapshots for charts
-- =============================================================================
CREATE TABLE IF NOT EXISTS pool_hourly_snapshots (
    snapshot_hour     TIMESTAMP WITH TIME ZONE PRIMARY KEY,
    balance           DOUBLE PRECISION NOT NULL,
    total_distributed DOUBLE PRECISION NOT NULL,
    total_reclaimed   DOUBLE PRECISION NOT NULL,
    created_at        TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================================
-- 17. USER_STREAKS — daily login streak tracking
-- =============================================================================
CREATE TABLE IF NOT EXISTS user_streaks (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    current_streak  INTEGER NOT NULL DEFAULT 0,
    longest_streak  INTEGER NOT NULL DEFAULT 0,
    last_login_date DATE,
    freeze_count    INTEGER NOT NULL DEFAULT 0,
    freeze_used_at  TIMESTAMP WITH TIME ZONE,
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================================
-- PREDICTION BOT TABLES (bot connects to fanzone_auth)
-- =============================================================================

CREATE TABLE IF NOT EXISTS bot_monitored_matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL UNIQUE,
    match_status VARCHAR(50) NOT NULL DEFAULT 'live',
    team1_name VARCHAR(100) NOT NULL DEFAULT '',
    team2_name VARCHAR(100) NOT NULL DEFAULT '',
    match_type VARCHAR(50) NOT NULL DEFAULT '',
    series_id VARCHAR(100) DEFAULT '',
    monitoring_started_at TIMESTAMPTZ DEFAULT NOW(),
    last_checked_at TIMESTAMPTZ DEFAULT NOW(),
    last_prediction_at TIMESTAMPTZ,
    predictions_created INT DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    match_context JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bot_matches_active ON bot_monitored_matches(is_active);

CREATE TABLE IF NOT EXISTS bot_predictions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id UUID NOT NULL,
    match_id VARCHAR(100) NOT NULL,
    prediction_type VARCHAR(50) NOT NULL,
    ai_reasoning TEXT DEFAULT '',
    ai_confidence FLOAT DEFAULT 0,
    suggested_odds JSONB DEFAULT '{}',
    final_odds JSONB DEFAULT '{}',
    house_edge_pct FLOAT DEFAULT 0,
    close_condition VARCHAR(50) DEFAULT '',
    close_trigger_data JSONB DEFAULT '{}',
    status VARCHAR(50) DEFAULT 'active',
    closed_reason VARCHAR(255) DEFAULT '',
    closed_at TIMESTAMPTZ,
    match_state_at_creation JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bot_preds_match ON bot_predictions(match_id);
CREATE INDEX IF NOT EXISTS idx_bot_preds_status ON bot_predictions(status);

CREATE TABLE IF NOT EXISTS bot_ai_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL,
    prompt_type VARCHAR(50) NOT NULL,
    prompt_hash VARCHAR(64) DEFAULT '',
    prompt_tokens INT DEFAULT 0,
    response_tokens INT DEFAULT 0,
    total_tokens INT DEFAULT 0,
    model_used VARCHAR(100) DEFAULT '',
    predictions_generated INT DEFAULT 0,
    predictions_accepted INT DEFAULT 0,
    predictions_rejected INT DEFAULT 0,
    rejection_reasons JSONB DEFAULT '[]',
    latency_ms INT DEFAULT 0,
    error TEXT DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS bot_config (
    key VARCHAR(100) PRIMARY KEY,
    value JSONB NOT NULL DEFAULT '{}',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO bot_config (key, value) VALUES
    ('bot_enabled', 'true'::jsonb),
    ('max_predictions_per_match', '10'::jsonb),
    ('prediction_interval_minutes', '5'::jsonb),
    ('max_active_per_match', '3'::jsonb)
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS bot_daily_stories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    story_date DATE NOT NULL UNIQUE,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- PREDICTION SERVICE TABLES (prediction service connects to fanzone_auth)
-- =============================================================================

CREATE TABLE IF NOT EXISTS prediction_markets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL,
    question VARCHAR(500) NOT NULL,
    description TEXT,
    market_type VARCHAR(50) NOT NULL,
    status VARCHAR(50) DEFAULT 'open',
    min_bet FLOAT NOT NULL DEFAULT 1.0,
    max_bet_per_user FLOAT,
    total_pool FLOAT DEFAULT 0,
    house_pool FLOAT DEFAULT 0,
    winning_option_id UUID,
    created_by UUID NOT NULL,
    resolved_by UUID,
    auto_resolve BOOLEAN DEFAULT false,
    resolution_rule JSONB,
    closes_at TIMESTAMPTZ NOT NULL,
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pred_markets_match ON prediction_markets(match_id);
CREATE INDEX IF NOT EXISTS idx_pred_markets_status ON prediction_markets(status);

CREATE TABLE IF NOT EXISTS prediction_options (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id UUID NOT NULL REFERENCES prediction_markets(id) ON DELETE CASCADE,
    label VARCHAR(255) NOT NULL,
    odds_multiplier FLOAT NOT NULL,
    total_bets INT DEFAULT 0,
    total_amount FLOAT DEFAULT 0,
    display_order INT DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_pred_options_market ON prediction_options(market_id);

CREATE TABLE IF NOT EXISTS prediction_bets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    market_id UUID NOT NULL REFERENCES prediction_markets(id),
    option_id UUID NOT NULL REFERENCES prediction_options(id),
    user_id UUID NOT NULL,
    amount FLOAT NOT NULL,
    house_fee FLOAT DEFAULT 0,
    odds_at_bet FLOAT NOT NULL,
    potential_payout FLOAT NOT NULL,
    status VARCHAR(50) DEFAULT 'active',
    actual_payout FLOAT,
    idempotency_key VARCHAR(255) UNIQUE,
    placed_at TIMESTAMPTZ DEFAULT NOW(),
    resolved_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_pred_bets_market ON prediction_bets(market_id);
CREATE INDEX IF NOT EXISTS idx_pred_bets_user ON prediction_bets(user_id);
CREATE INDEX IF NOT EXISTS idx_pred_bets_status ON prediction_bets(status);

CREATE TABLE IF NOT EXISTS prediction_house_pool (
    id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    total_fees FLOAT DEFAULT 0,
    total_bets_count INT DEFAULT 0,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO prediction_house_pool (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- AI prediction agent columns
ALTER TABLE prediction_markets ADD COLUMN IF NOT EXISTS image_url TEXT;
ALTER TABLE prediction_markets ADD COLUMN IF NOT EXISTS category TEXT DEFAULT 'sports';
ALTER TABLE prediction_markets ADD COLUMN IF NOT EXISTS source_url TEXT;
ALTER TABLE prediction_markets ADD COLUMN IF NOT EXISTS ai_generated BOOLEAN DEFAULT FALSE;
ALTER TABLE prediction_markets ADD COLUMN IF NOT EXISTS ai_provider TEXT;

CREATE INDEX IF NOT EXISTS idx_pred_markets_category ON prediction_markets(category) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS idx_pred_markets_ai_generated ON prediction_markets(ai_generated) WHERE status = 'open';

-- AI generation run tracking
CREATE TABLE IF NOT EXISTS ai_generation_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_type TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    prompt_hash TEXT,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    total_tokens INTEGER DEFAULT 0,
    latency_ms INTEGER DEFAULT 0,
    predictions_generated INTEGER DEFAULT 0,
    predictions_published INTEGER DEFAULT 0,
    predictions_resolved INTEGER DEFAULT 0,
    error TEXT,
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ai_gen_runs_created ON ai_generation_runs(created_at DESC);

-- =============================================================================
-- USER SERVICE TABLES (user service connects to fanzone_auth)
-- =============================================================================

CREATE TABLE IF NOT EXISTS user_badges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    badge_id VARCHAR(100) NOT NULL,
    badge_name VARCHAR(100) NOT NULL,
    description TEXT,
    icon VARCHAR(255),
    metadata JSONB,
    earned_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, badge_id)
);
CREATE INDEX IF NOT EXISTS idx_user_badges_user ON user_badges(user_id);
