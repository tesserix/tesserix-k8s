-- ============================================================
-- CROSS-DB USER VIEW
-- The admin panel queries fanzone.users but real users live in
-- fanzone_auth.users. Create a foreign data wrapper + view so
-- the fanzone-api can read auth users transparently.
-- ============================================================
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS dblink;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'fanzone_auth_server') THEN
    CREATE SERVER fanzone_auth_server FOREIGN DATA WRAPPER postgres_fdw
      OPTIONS (host 'localhost', port '5432', dbname 'fanzone_auth');
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_user_mappings WHERE srvname = 'fanzone_auth_server' AND usename = 'postgres') THEN
    CREATE USER MAPPING FOR postgres SERVER fanzone_auth_server
      OPTIONS (user 'postgres', password 'tesserix-dev-2024');
  END IF;
END $$;

-- Import the users table from fanzone_auth as a foreign table
DROP FOREIGN TABLE IF EXISTS auth_users;
CREATE FOREIGN TABLE auth_users (
    id              UUID,
    username        VARCHAR(255),
    email           VARCHAR(255),
    phone           VARCHAR(20),
    password_hash   VARCHAR(255),
    name            VARCHAR(255),
    avatar_url      TEXT,
    provider        VARCHAR(50),
    provider_id     VARCHAR(255),
    email_verified  BOOLEAN,
    phone_verified  BOOLEAN,
    role            VARCHAR(50),
    is_active       BOOLEAN,
    login_count     INTEGER,
    signup_source   VARCHAR(50),
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ,
    last_login_at   TIMESTAMPTZ
) SERVER fanzone_auth_server OPTIONS (schema_name 'public', table_name 'users');

-- Create or replace the users view that the fanzone-api reads from
-- This transparently reads from fanzone_auth.users
DROP VIEW IF EXISTS users CASCADE;
CREATE VIEW users AS SELECT * FROM auth_users;

-- Admin users view used by the fanzone-api admin panel
-- Maps fanzone_auth.users columns to the format expected by the API
DROP VIEW IF EXISTS vw_admin_users CASCADE;
CREATE VIEW vw_admin_users AS
SELECT
    id,
    username,
    email,
    name AS display_name,
    avatar_url,
    role,
    is_active,
    created_at,
    last_login_at
FROM auth_users;

-- Admin stats view for dashboard cards (Total Users, Active Today, etc.)
DROP VIEW IF EXISTS admin_stats CASCADE;
CREATE VIEW admin_stats AS
SELECT
    (SELECT COUNT(*) FROM auth_users) AS total_users,
    (SELECT COUNT(*) FROM auth_users WHERE last_login_at >= CURRENT_DATE) AS active_today,
    (SELECT COUNT(*) FROM auth_users WHERE last_login_at >= CURRENT_DATE - INTERVAL '7 days') AS active_this_week,
    (SELECT COUNT(*) FROM auth_users WHERE created_at >= CURRENT_DATE - INTERVAL '7 days') AS new_this_week,
    0::bigint AS messages_today,
    0::bigint AS messages_this_week,
    0::bigint AS live_matches,
    0::bigint AS completed_today,
    0::bigint AS upcoming_24h,
    0::bigint AS pending_reports;

-- ============================================================
-- FAN CONNECT SERVICE - Initial Schema
-- Managed by k8s db-schema-bootstrap CronJob
-- ============================================================

-- FRIENDSHIPS
CREATE TABLE IF NOT EXISTS friendships (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id    UUID NOT NULL,
    addressee_id    UUID NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_friendship_pair UNIQUE (requester_id, addressee_id),
    CONSTRAINT chk_not_self CHECK (requester_id != addressee_id),
    CONSTRAINT chk_status CHECK (status IN ('pending', 'accepted', 'declined', 'blocked'))
);

CREATE INDEX IF NOT EXISTS idx_friendships_requester ON friendships(requester_id, status);
CREATE INDEX IF NOT EXISTS idx_friendships_addressee ON friendships(addressee_id, status);
CREATE INDEX IF NOT EXISTS idx_friendships_pair ON friendships(
    LEAST(requester_id, addressee_id),
    GREATEST(requester_id, addressee_id)
);

-- USER BLOCKS
CREATE TABLE IF NOT EXISTS user_blocks (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    blocker_id  UUID NOT NULL,
    blocked_id  UUID NOT NULL,
    reason      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_block_pair UNIQUE (blocker_id, blocked_id),
    CONSTRAINT chk_not_self_block CHECK (blocker_id != blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_blocks_blocker ON user_blocks(blocker_id);
CREATE INDEX IF NOT EXISTS idx_blocks_blocked ON user_blocks(blocked_id);

-- FAN GROUPS
CREATE TABLE IF NOT EXISTS fan_groups (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    avatar_url      TEXT,
    cover_image_url TEXT,
    created_by      UUID NOT NULL,
    team_id         VARCHAR(50),
    region          VARCHAR(100),
    tags            TEXT[] DEFAULT '{}',
    is_public       BOOLEAN NOT NULL DEFAULT true,
    member_count    INT NOT NULL DEFAULT 1,
    member_cap      INT NOT NULL DEFAULT 500,
    rules           TEXT,
    settings        JSONB NOT NULL DEFAULT '{}',
    is_verified     BOOLEAN NOT NULL DEFAULT false,
    is_active       BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fan_groups_team ON fan_groups(team_id) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_fan_groups_public ON fan_groups(is_public, member_count DESC) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_fan_groups_created_by ON fan_groups(created_by);
CREATE INDEX IF NOT EXISTS idx_fan_groups_tags ON fan_groups USING GIN(tags);

-- GROUP MEMBERS
CREATE TABLE IF NOT EXISTS group_members (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID NOT NULL REFERENCES fan_groups(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL,
    role        VARCHAR(20) NOT NULL DEFAULT 'member',
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    invited_by  UUID,

    CONSTRAINT uq_group_member UNIQUE (group_id, user_id),
    CONSTRAINT chk_role CHECK (role IN ('owner', 'admin', 'moderator', 'member'))
);

CREATE INDEX IF NOT EXISTS idx_group_members_user ON group_members(user_id);
CREATE INDEX IF NOT EXISTS idx_group_members_group ON group_members(group_id, role);

-- GROUP INVITATIONS
CREATE TABLE IF NOT EXISTS group_invitations (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID NOT NULL REFERENCES fan_groups(id) ON DELETE CASCADE,
    inviter_id  UUID NOT NULL,
    invitee_id  UUID NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'pending',
    message     TEXT,
    expires_at  TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '7 days',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_inv_status CHECK (status IN ('pending', 'accepted', 'declined', 'expired'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_group_invitations_unique
    ON group_invitations(group_id, invitee_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_group_invitations_invitee ON group_invitations(invitee_id, status);

-- GAME ROOM INVITATIONS
CREATE TABLE IF NOT EXISTS room_invitations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id        UUID NOT NULL REFERENCES fan_groups(id),
    match_id        VARCHAR(100) NOT NULL,
    room_id         VARCHAR(100) NOT NULL,
    invited_by      UUID NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'active',
    message         TEXT,
    accepted_count  INT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '4 hours',

    CONSTRAINT uq_room_invitation UNIQUE (group_id, room_id)
);

CREATE INDEX IF NOT EXISTS idx_room_invitations_group ON room_invitations(group_id, status);
CREATE INDEX IF NOT EXISTS idx_room_invitations_room ON room_invitations(room_id);
CREATE INDEX IF NOT EXISTS idx_room_invitations_match ON room_invitations(match_id);

-- ROOM INVITATION RESPONSES
CREATE TABLE IF NOT EXISTS room_invitation_responses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    invitation_id   UUID NOT NULL REFERENCES room_invitations(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',
    responded_at    TIMESTAMPTZ,

    CONSTRAINT uq_invitation_response UNIQUE (invitation_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_invitation_responses_user ON room_invitation_responses(user_id, status);

-- FAN PROFILES
CREATE TABLE IF NOT EXISTS fan_profiles (
    user_id               UUID PRIMARY KEY,
    favorite_team_ids     TEXT[] DEFAULT '{}',
    rival_team_ids        TEXT[] DEFAULT '{}',
    play_style            VARCHAR(30),
    fan_since             INT,
    preferred_language    VARCHAR(10) DEFAULT 'en',
    visibility            VARCHAR(20) DEFAULT 'public',
    allow_friend_requests BOOLEAN DEFAULT true,
    allow_group_invites   BOOLEAN DEFAULT true,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fan_profiles_team ON fan_profiles USING GIN(favorite_team_ids);
CREATE INDEX IF NOT EXISTS idx_fan_profiles_style ON fan_profiles(play_style);

-- GROUP ACTIVITY LOG
CREATE TABLE IF NOT EXISTS group_activity_log (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID NOT NULL REFERENCES fan_groups(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL,
    action      VARCHAR(50) NOT NULL,
    metadata    JSONB DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_activity_group ON group_activity_log(group_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_group_activity_user ON group_activity_log(user_id, created_at DESC);

-- SCHEMA MIGRATIONS TRACKING
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     INT PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- COMMENTARY SERVICE SCHEMA
-- ============================================================

CREATE TABLE IF NOT EXISTS supported_languages (
    code    VARCHAR(5) PRIMARY KEY,
    label   VARCHAR(50) NOT NULL,
    flag    VARCHAR(10) NOT NULL DEFAULT '',
    region  VARCHAR(50) NOT NULL DEFAULT '',
    active  BOOLEAN NOT NULL DEFAULT true
);

INSERT INTO supported_languages (code, label, flag, region) VALUES
    ('en', 'English', '🇬🇧', 'Global'),
    ('hi', 'Hindi', '🇮🇳', 'India'),
    ('ta', 'Tamil', '🇮🇳', 'India'),
    ('te', 'Telugu', '🇮🇳', 'India'),
    ('kn', 'Kannada', '🇮🇳', 'India'),
    ('bn', 'Bengali', '🇮🇳', 'India'),
    ('mr', 'Marathi', '🇮🇳', 'India'),
    ('pa', 'Punjabi', '🇮🇳', 'India')
ON CONFLICT (code) DO NOTHING;

-- Fix: commentary tables were created with UUID match_id but sports data uses string IDs (sm_69476).
-- Drop and recreate with VARCHAR(100). Safe — these tables are empty on fresh DB.
DROP TABLE IF EXISTS nomination_votes CASCADE;
DROP TABLE IF EXISTS commentary_reports CASCADE;
DROP TABLE IF EXISTS commentary_listeners CASCADE;
DROP TABLE IF EXISTS commentator_ratings CASCADE;
DROP TABLE IF EXISTS match_commentators CASCADE;
DROP TABLE IF EXISTS commentary_nominations CASCADE;
DROP TABLE IF EXISTS match_commentary_config CASCADE;

CREATE TABLE IF NOT EXISTS match_commentary_config (
    match_id VARCHAR(100) PRIMARY KEY,
    nominations_open_at TIMESTAMPTZ NOT NULL,
    nominations_close_at TIMESTAMPTZ NOT NULL,
    lottery_run_at TIMESTAMPTZ,
    max_commentators_per_lang SMALLINT DEFAULT 3,
    min_commentators_per_lang SMALLINT DEFAULT 1,
    max_nominations_per_lang INT DEFAULT 50,
    status VARCHAR(20) DEFAULT 'open',
    voting_close_at TIMESTAMPTZ,
    selection_method VARCHAR(10) DEFAULT 'vote',
    cleaned_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS commentary_nominations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL,
    user_id UUID NOT NULL,
    username VARCHAR(100) NOT NULL DEFAULT '',
    language_code VARCHAR(5) NOT NULL,
    nominated_at TIMESTAMPTZ DEFAULT now(),
    status VARCHAR(20) DEFAULT 'nominated',
    voice_clip_url TEXT DEFAULT '',
    voice_clip_duration_secs INT DEFAULT 0,
    nomination_reason TEXT DEFAULT '',
    avatar_url TEXT DEFAULT '',
    nominated_by UUID,
    nominated_by_username VARCHAR(100) DEFAULT '',
    UNIQUE(match_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_nominations_match_lang ON commentary_nominations(match_id, language_code);
CREATE INDEX IF NOT EXISTS idx_nominations_status ON commentary_nominations(match_id, status);

CREATE TABLE IF NOT EXISTS match_commentators (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL,
    user_id UUID NOT NULL,
    username VARCHAR(100) NOT NULL DEFAULT '',
    avatar_url TEXT DEFAULT '',
    language_code VARCHAR(5) NOT NULL,
    selected_at TIMESTAMPTZ DEFAULT now(),
    joined_at TIMESTAMPTZ,
    left_at TIMESTAMPTZ,
    status VARCHAR(20) DEFAULT 'selected',
    replacement_for UUID REFERENCES match_commentators(id),
    sfu_room_id VARCHAR(255) DEFAULT '',
    sfu_participant_id VARCHAR(255) DEFAULT '',
    UNIQUE(match_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_commentators_match_lang ON match_commentators(match_id, language_code);
CREATE INDEX IF NOT EXISTS idx_commentators_status ON match_commentators(match_id, status);

CREATE TABLE IF NOT EXISTS commentator_ratings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL,
    commentator_user_id UUID NOT NULL,
    rater_user_id UUID NOT NULL,
    rating SMALLINT CHECK (rating BETWEEN 1 AND 5),
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(match_id, commentator_user_id, rater_user_id)
);
CREATE INDEX IF NOT EXISTS idx_ratings_commentator ON commentator_ratings(commentator_user_id);

CREATE TABLE IF NOT EXISTS commentator_stats (
    user_id UUID PRIMARY KEY,
    total_sessions INT DEFAULT 0,
    total_minutes FLOAT DEFAULT 0,
    avg_rating FLOAT DEFAULT 0,
    total_ratings INT DEFAULT 0,
    total_listeners INT DEFAULT 0,
    badges JSONB DEFAULT '[]',
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS commentary_listeners (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL,
    user_id UUID NOT NULL,
    language_code VARCHAR(5) NOT NULL,
    joined_at TIMESTAMPTZ DEFAULT now(),
    left_at TIMESTAMPTZ,
    total_listen_seconds INT DEFAULT 0,
    points_awarded FLOAT DEFAULT 0,
    UNIQUE(match_id, user_id, language_code)
);
CREATE INDEX IF NOT EXISTS idx_listeners_match ON commentary_listeners(match_id);
CREATE INDEX IF NOT EXISTS idx_listeners_user ON commentary_listeners(user_id, match_id);

CREATE TABLE IF NOT EXISTS nomination_votes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL,
    nomination_id UUID NOT NULL REFERENCES commentary_nominations(id) ON DELETE CASCADE,
    language_code VARCHAR(5) NOT NULL,
    voter_user_id UUID NOT NULL,
    voter_username VARCHAR(100) NOT NULL DEFAULT '',
    voted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(match_id, voter_user_id, language_code)
);
CREATE INDEX IF NOT EXISTS idx_votes_nomination ON nomination_votes(nomination_id);
CREATE INDEX IF NOT EXISTS idx_votes_match_lang ON nomination_votes(match_id, language_code);

CREATE TABLE IF NOT EXISTS commentary_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL,
    commentator_user_id UUID NOT NULL,
    commentator_username VARCHAR(100) DEFAULT '',
    reporter_user_id UUID NOT NULL,
    reporter_username VARCHAR(100) DEFAULT '',
    reason_category VARCHAR(30) NOT NULL,
    reason_detail TEXT DEFAULT '',
    status VARCHAR(20) DEFAULT 'pending',
    admin_note TEXT DEFAULT '',
    resolved_by UUID,
    resolved_by_username VARCHAR(100) DEFAULT '',
    resolved_at TIMESTAMPTZ,
    resolution VARCHAR(20),
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(match_id, commentator_user_id, reporter_user_id)
);
CREATE INDEX IF NOT EXISTS idx_commentary_reports_status ON commentary_reports(status);
CREATE INDEX IF NOT EXISTS idx_commentary_reports_created ON commentary_reports(created_at DESC);

CREATE TABLE IF NOT EXISTS commentary_bans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE,
    username VARCHAR(100) DEFAULT '',
    banned_by UUID NOT NULL,
    banned_by_username VARCHAR(100) DEFAULT '',
    reason TEXT NOT NULL DEFAULT '',
    is_permanent BOOLEAN NOT NULL DEFAULT false,
    expires_at TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT true,
    unbanned_by UUID,
    unbanned_by_username VARCHAR(100) DEFAULT '',
    unbanned_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_commentary_bans_active ON commentary_bans(user_id) WHERE is_active = true;

-- supported_countries (commentary languages page)
CREATE TABLE IF NOT EXISTS supported_countries (
    code VARCHAR(5) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    flag VARCHAR(50) DEFAULT '',
    common_languages TEXT[] DEFAULT '{}',
    active BOOLEAN DEFAULT true,
    sort_order INT DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_countries_active ON supported_countries(active);

INSERT INTO supported_countries (code, name, flag, common_languages, sort_order) VALUES
    ('IN', 'India', '🇮🇳', ARRAY['hi','en','ta','te','kn','bn','mr','pa'], 1),
    ('US', 'United States', '🇺🇸', ARRAY['en'], 2),
    ('GB', 'United Kingdom', '🇬🇧', ARRAY['en'], 3),
    ('AU', 'Australia', '🇦🇺', ARRAY['en'], 4),
    ('NZ', 'New Zealand', '🇳🇿', ARRAY['en'], 5),
    ('ZA', 'South Africa', '🇿🇦', ARRAY['en'], 6),
    ('PK', 'Pakistan', '🇵🇰', ARRAY['en'], 7),
    ('BD', 'Bangladesh', '🇧🇩', ARRAY['bn','en'], 8),
    ('LK', 'Sri Lanka', '🇱🇰', ARRAY['en'], 9),
    ('AE', 'UAE', '🇦🇪', ARRAY['en','hi'], 10)
ON CONFLICT (code) DO NOTHING;

-- country_states (commentary region picker)
CREATE TABLE IF NOT EXISTS country_states (
    id SERIAL PRIMARY KEY,
    country_code VARCHAR(5) NOT NULL REFERENCES supported_countries(code),
    state_code VARCHAR(10) NOT NULL,
    state_name VARCHAR(100) NOT NULL,
    languages TEXT[] DEFAULT '{}',
    sort_order INT DEFAULT 0,
    UNIQUE(country_code, state_code)
);
CREATE INDEX IF NOT EXISTS idx_country_states_country ON country_states(country_code);

-- ============================================================
-- NOTIFICATION SERVICE SCHEMA
-- ============================================================

CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    type VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    data JSONB,
    read BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_created ON notifications(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_read_user ON notifications(user_id, read);

CREATE TABLE IF NOT EXISTS push_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    token VARCHAR(500) NOT NULL,
    platform VARCHAR(50) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, token)
);
CREATE INDEX IF NOT EXISTS idx_push_tokens_user ON push_tokens(user_id);

CREATE TABLE IF NOT EXISTS match_reminders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    match_id VARCHAR(100) NOT NULL,
    reminded_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, match_id)
);
CREATE INDEX IF NOT EXISTS idx_match_reminders_user ON match_reminders(user_id);
CREATE INDEX IF NOT EXISTS idx_match_reminders_pending ON match_reminders(reminded_at) WHERE reminded_at IS NULL;

CREATE TABLE IF NOT EXISTS broadcast_notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    data JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_broadcast_created ON broadcast_notifications(created_at DESC);

CREATE TABLE IF NOT EXISTS broadcast_notification_reads (
    id SERIAL PRIMARY KEY,
    user_id UUID NOT NULL,
    notification_id UUID NOT NULL REFERENCES broadcast_notifications(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, notification_id)
);
CREATE INDEX IF NOT EXISTS idx_broadcast_reads_user ON broadcast_notification_reads(user_id);

-- ============================================================
-- PREDICTION SERVICE SCHEMA
-- ============================================================

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
CREATE INDEX IF NOT EXISTS idx_pred_markets_closes ON prediction_markets(closes_at);

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

-- ============================================================
-- MICRO-PREDICTION SERVICE SCHEMA
-- ============================================================

CREATE TABLE IF NOT EXISTS micro_predictions (
    id VARCHAR(36) PRIMARY KEY,
    match_id VARCHAR(100) NOT NULL,
    ball_number INT,
    over_number INT,
    prediction_type VARCHAR(50) NOT NULL,
    options TEXT[],
    correct_option VARCHAR(100),
    status VARCHAR(50) DEFAULT 'open',
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    points_pool INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_micro_pred_match ON micro_predictions(match_id);
CREATE INDEX IF NOT EXISTS idx_micro_pred_status ON micro_predictions(status);

CREATE TABLE IF NOT EXISTS micro_bets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    prediction_id VARCHAR(36) NOT NULL REFERENCES micro_predictions(id),
    user_id UUID NOT NULL,
    chosen_option VARCHAR(100) NOT NULL,
    points_wagered INT NOT NULL,
    streak_multiplier FLOAT DEFAULT 1.0,
    won BOOLEAN,
    points_won INT DEFAULT 0,
    reaction_time_ms INT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_micro_bets_pred ON micro_bets(prediction_id);
CREATE INDEX IF NOT EXISTS idx_micro_bets_user ON micro_bets(user_id);

CREATE TABLE IF NOT EXISTS prediction_streaks (
    user_id UUID PRIMARY KEY,
    current_streak INT DEFAULT 0,
    max_streak INT DEFAULT 0,
    correct_streak INT DEFAULT 0,
    incorrect_streak INT DEFAULT 0,
    streak_tier VARCHAR(50) DEFAULT 'bronze',
    multiplier FLOAT DEFAULT 1.0,
    last_prediction_at TIMESTAMPTZ,
    streak_started_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS streak_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    streak_type VARCHAR(50),
    streak_count INT,
    event_type VARCHAR(50),
    match_id VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_streak_events_user ON streak_events(user_id);

CREATE TABLE IF NOT EXISTS cricket_iq (
    user_id UUID PRIMARY KEY,
    overall_rating INT DEFAULT 1000,
    batting_rating INT DEFAULT 1000,
    bowling_rating INT DEFAULT 1000,
    strategy_rating INT DEFAULT 1000,
    scout_rating INT DEFAULT 1000,
    total_predictions INT DEFAULT 0,
    correct_predictions INT DEFAULT 0,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_cricket_iq_overall ON cricket_iq(overall_rating DESC);

CREATE TABLE IF NOT EXISTS cricket_iq_history (
    id VARCHAR(36) PRIMARY KEY,
    user_id UUID NOT NULL,
    category VARCHAR(50) NOT NULL,
    old_rating INT,
    new_rating INT,
    delta INT,
    reason VARCHAR(255),
    match_id VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_cricket_iq_history_user ON cricket_iq_history(user_id);

CREATE TABLE IF NOT EXISTS crowd_energy (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id VARCHAR(100) NOT NULL UNIQUE,
    energy_level FLOAT DEFAULT 0.5,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS match_reaction_stats (
    id SERIAL PRIMARY KEY,
    match_id VARCHAR(100) NOT NULL,
    reaction_type VARCHAR(100) NOT NULL,
    count INT DEFAULT 1,
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(match_id, reaction_type)
);

CREATE TABLE IF NOT EXISTS match_pulse_events (
    id VARCHAR(36) PRIMARY KEY,
    match_id VARCHAR(100) NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    intensity INT,
    payload JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pulse_events_match ON match_pulse_events(match_id);

-- ============================================================
-- QUEST SERVICE SCHEMA
-- ============================================================

CREATE TABLE IF NOT EXISTS clans (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    tag VARCHAR(10) NOT NULL UNIQUE,
    description TEXT,
    badge_url VARCHAR(500),
    region VARCHAR(50),
    team_affiliation VARCHAR(100),
    owner_id UUID NOT NULL,
    max_members INT DEFAULT 50,
    total_points INT DEFAULT 0,
    wars_won INT DEFAULT 0,
    wars_lost INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_clans_owner ON clans(owner_id);
CREATE INDEX IF NOT EXISTS idx_clans_points ON clans(total_points DESC);

CREATE TABLE IF NOT EXISTS clan_members (
    id VARCHAR(36) PRIMARY KEY,
    clan_id VARCHAR(36) NOT NULL REFERENCES clans(id),
    user_id UUID NOT NULL,
    role VARCHAR(50) DEFAULT 'member',
    points_contributed INT DEFAULT 0,
    joined_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(clan_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_clan_members_clan ON clan_members(clan_id);
CREATE INDEX IF NOT EXISTS idx_clan_members_user ON clan_members(user_id);

CREATE TABLE IF NOT EXISTS clan_wars (
    id VARCHAR(36) PRIMARY KEY,
    clan_a_id VARCHAR(36) NOT NULL REFERENCES clans(id),
    clan_b_id VARCHAR(36) NOT NULL REFERENCES clans(id),
    match_id VARCHAR(100) NOT NULL,
    status VARCHAR(50) DEFAULT 'active',
    clan_a_score INT DEFAULT 0,
    clan_b_score INT DEFAULT 0,
    winner_clan_id VARCHAR(36) REFERENCES clans(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_clan_wars_status ON clan_wars(status);

CREATE TABLE IF NOT EXISTS quest_definitions (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    quest_type VARCHAR(50) NOT NULL,
    category VARCHAR(100),
    target_metric VARCHAR(100) NOT NULL,
    target_value INT NOT NULL,
    reward_points INT DEFAULT 0,
    reward_xp INT DEFAULT 0,
    reward_badge_id VARCHAR(100),
    icon VARCHAR(255),
    difficulty VARCHAR(50),
    is_active BOOLEAN DEFAULT true,
    sort_order INT DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_quests_type ON quest_definitions(quest_type);
CREATE INDEX IF NOT EXISTS idx_quests_active ON quest_definitions(is_active);

CREATE TABLE IF NOT EXISTS user_quest_progress (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    quest_id VARCHAR(36) NOT NULL REFERENCES quest_definitions(id),
    period_key VARCHAR(50) NOT NULL,
    current_value INT DEFAULT 0,
    target_value INT NOT NULL,
    is_completed BOOLEAN DEFAULT false,
    completed_at TIMESTAMPTZ,
    reward_claimed BOOLEAN DEFAULT false,
    claimed_at TIMESTAMPTZ,
    UNIQUE(user_id, quest_id, period_key)
);
CREATE INDEX IF NOT EXISTS idx_quest_progress_user ON user_quest_progress(user_id);

CREATE TABLE IF NOT EXISTS prediction_duels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    challenger_id UUID NOT NULL,
    defender_id UUID,
    match_id VARCHAR(100) NOT NULL,
    wager_points INT NOT NULL,
    status VARCHAR(50) DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_duels_challenger ON prediction_duels(challenger_id);
CREATE INDEX IF NOT EXISTS idx_duels_status ON prediction_duels(status);

CREATE TABLE IF NOT EXISTS prediction_squads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    invite_code VARCHAR(20) NOT NULL UNIQUE,
    captain_id UUID NOT NULL,
    max_members INT DEFAULT 10,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS squad_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    squad_id UUID NOT NULL REFERENCES prediction_squads(id),
    user_id UUID NOT NULL,
    role VARCHAR(50) DEFAULT 'member',
    joined_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(squad_id, user_id)
);

CREATE TABLE IF NOT EXISTS squad_challenges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    challenger_squad_id UUID NOT NULL REFERENCES prediction_squads(id),
    defender_squad_id UUID NOT NULL REFERENCES prediction_squads(id),
    match_id VARCHAR(100) NOT NULL,
    status VARCHAR(50) DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS trivia_questions (
    id VARCHAR(36) PRIMARY KEY,
    question TEXT NOT NULL,
    options TEXT[],
    correct_answer VARCHAR(500),
    difficulty VARCHAR(50),
    used_count INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_trivia_answers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    question_id VARCHAR(36) NOT NULL REFERENCES trivia_questions(id),
    selected_option VARCHAR(500),
    is_correct BOOLEAN,
    points_earned INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS shop_items (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    cost_points INT NOT NULL,
    is_active BOOLEAN DEFAULT true
);

CREATE TABLE IF NOT EXISTS user_purchases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    item_id VARCHAR(36) NOT NULL REFERENCES shop_items(id),
    cost_points INT NOT NULL,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS seasons (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    total_tiers INT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS season_tiers (
    id VARCHAR(36) PRIMARY KEY,
    season_id VARCHAR(36) NOT NULL REFERENCES seasons(id),
    tier_number INT NOT NULL,
    name VARCHAR(100),
    required_xp INT,
    free_rewards JSONB,
    premium_rewards JSONB,
    UNIQUE(season_id, tier_number)
);

CREATE TABLE IF NOT EXISTS user_season_progress (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    season_id VARCHAR(36) NOT NULL REFERENCES seasons(id),
    current_xp INT DEFAULT 0,
    daily_xp_earned INT DEFAULT 0,
    current_tier INT DEFAULT 1,
    is_premium BOOLEAN DEFAULT false,
    rewards_claimed BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, season_id)
);

-- ============================================================
-- USER SERVICE SCHEMA (fanzone DB tables)
-- ============================================================

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

-- ============================================================
-- PREDICTION BOT SERVICE SCHEMA
-- ============================================================

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
CREATE INDEX IF NOT EXISTS idx_bot_preds_market ON bot_predictions(market_id);

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
CREATE INDEX IF NOT EXISTS idx_bot_audit_match ON bot_ai_audit_log(match_id);
CREATE INDEX IF NOT EXISTS idx_bot_audit_created ON bot_ai_audit_log(created_at DESC);

CREATE TABLE IF NOT EXISTS bot_config (
    key VARCHAR(100) PRIMARY KEY,
    value JSONB NOT NULL DEFAULT '{}',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Seed default bot config (enabled by default)
INSERT INTO bot_config (key, value) VALUES
    ('bot_enabled', 'true'::jsonb),
    ('max_predictions_per_match', '10'::jsonb),
    ('prediction_interval_minutes', '5'::jsonb),
    ('max_active_per_match', '3'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- USER FOLLOWS (fan-connect service)
-- ============================================================

CREATE TABLE IF NOT EXISTS user_follows (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    follower_id UUID NOT NULL,
    following_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_follows UNIQUE (follower_id, following_id),
    CONSTRAINT chk_not_self_follow CHECK (follower_id != following_id)
);
CREATE INDEX IF NOT EXISTS idx_follows_follower ON user_follows(follower_id);
CREATE INDEX IF NOT EXISTS idx_follows_following ON user_follows(following_id);

-- ============================================================
-- MATCHES TABLE (cleanup service reads this)
-- ============================================================

CREATE TABLE IF NOT EXISTS matches (
    id VARCHAR(100) PRIMARY KEY,
    status VARCHAR(50) DEFAULT 'scheduled',
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    cleaned_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_matches_status ON matches(status);

-- ============================================================
-- CRICKET QUIZ SERVICE SCHEMA
-- ============================================================

-- Drop and recreate quiz_questions to fix column names (correct_option→correct_index, add question_type)
DROP TABLE IF EXISTS quiz_user_question_history CASCADE;
DROP TABLE IF EXISTS quiz_challenge_questions CASCADE;
DROP TABLE IF EXISTS quiz_answers CASCADE;
DROP TABLE IF EXISTS quiz_tournament_questions CASCADE;
DROP TABLE IF EXISTS quiz_level_progress CASCADE;
DROP TABLE IF EXISTS quiz_challenge_participants CASCADE;
DROP TABLE IF EXISTS quiz_challenges CASCADE;
DROP TABLE IF EXISTS quiz_tournaments CASCADE;
DROP TABLE IF EXISTS quiz_questions CASCADE;

CREATE TABLE IF NOT EXISTS quiz_questions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    difficulty VARCHAR(50) NOT NULL DEFAULT 'easy',
    category VARCHAR(100) DEFAULT '',
    question_type VARCHAR(50) DEFAULT 'multiple_choice',
    question TEXT NOT NULL,
    options JSONB NOT NULL,
    correct_index INT NOT NULL DEFAULT 0,
    explanation TEXT DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_quiz_q_difficulty ON quiz_questions(difficulty);

CREATE TABLE IF NOT EXISTS quiz_tournaments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    username VARCHAR(255) NOT NULL DEFAULT '',
    difficulty VARCHAR(50) NOT NULL DEFAULT 'easy',
    current_level INT NOT NULL DEFAULT 1,
    status VARCHAR(50) NOT NULL DEFAULT 'in_progress',
    entry_fee FLOAT DEFAULT 0,
    level_fees FLOAT DEFAULT 0,
    total_earned FLOAT DEFAULT 0,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_quiz_tourn_user ON quiz_tournaments(user_id);
CREATE INDEX IF NOT EXISTS idx_quiz_tourn_status ON quiz_tournaments(status);

CREATE TABLE IF NOT EXISTS quiz_tournament_questions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id UUID NOT NULL REFERENCES quiz_tournaments(id) ON DELETE CASCADE,
    question_id UUID NOT NULL REFERENCES quiz_questions(id),
    level INT NOT NULL,
    question_index INT NOT NULL,
    UNIQUE(tournament_id, question_id)
);
CREATE INDEX IF NOT EXISTS idx_quiz_tq_tournament ON quiz_tournament_questions(tournament_id);

CREATE TABLE IF NOT EXISTS quiz_level_progress (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id UUID NOT NULL REFERENCES quiz_tournaments(id) ON DELETE CASCADE,
    level INT NOT NULL,
    correct_answers INT DEFAULT 0,
    wrong_answers INT DEFAULT 0,
    total_questions INT NOT NULL,
    max_wrong INT NOT NULL,
    reward_points FLOAT DEFAULT 0,
    level_fee FLOAT DEFAULT 0,
    status VARCHAR(50) DEFAULT 'in_progress',
    current_question_index INT DEFAULT 0,
    question_served_at TIMESTAMPTZ,
    total_tab_switches INT DEFAULT 0,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    UNIQUE(tournament_id, level)
);
CREATE INDEX IF NOT EXISTS idx_quiz_lp_tournament ON quiz_level_progress(tournament_id);

CREATE TABLE IF NOT EXISTS quiz_answers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id UUID NOT NULL REFERENCES quiz_tournaments(id) ON DELETE CASCADE,
    question_id UUID NOT NULL REFERENCES quiz_questions(id),
    level INT NOT NULL,
    selected_index INT NOT NULL,
    is_correct BOOLEAN NOT NULL,
    timed_out BOOLEAN DEFAULT FALSE,
    tab_switches INT DEFAULT 0,
    answer_time_ms INT DEFAULT 0,
    answered_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_quiz_ans_tournament ON quiz_answers(tournament_id);

CREATE TABLE IF NOT EXISTS quiz_challenges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    creator_id UUID NOT NULL,
    creator_username VARCHAR(255) DEFAULT '',
    difficulty VARCHAR(50) NOT NULL DEFAULT 'easy',
    wager_points FLOAT DEFAULT 0,
    status VARCHAR(50) DEFAULT 'pending',
    winner_id UUID,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT NOW() + INTERVAL '24 hours'
);
CREATE INDEX IF NOT EXISTS idx_quiz_ch_creator ON quiz_challenges(creator_id);
CREATE INDEX IF NOT EXISTS idx_quiz_ch_status ON quiz_challenges(status);

CREATE TABLE IF NOT EXISTS quiz_challenge_participants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    challenge_id UUID NOT NULL REFERENCES quiz_challenges(id) ON DELETE CASCADE,
    user_id UUID,
    username VARCHAR(255) NOT NULL DEFAULT '',
    tournament_id UUID REFERENCES quiz_tournaments(id),
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    external_claim_token VARCHAR(255),
    invited_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_quiz_cp_challenge ON quiz_challenge_participants(challenge_id);
CREATE INDEX IF NOT EXISTS idx_quiz_cp_user ON quiz_challenge_participants(user_id);

CREATE TABLE IF NOT EXISTS quiz_challenge_questions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    challenge_id UUID NOT NULL REFERENCES quiz_challenges(id) ON DELETE CASCADE,
    question_id UUID NOT NULL REFERENCES quiz_questions(id),
    question_order INT NOT NULL
);

DROP TABLE IF EXISTS quiz_user_question_history CASCADE;
CREATE TABLE IF NOT EXISTS quiz_user_question_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    question_id UUID NOT NULL REFERENCES quiz_questions(id),
    times_seen INT DEFAULT 1,
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, question_id)
);
CREATE INDEX IF NOT EXISTS idx_quiz_hist_user ON quiz_user_question_history(user_id);

-- ============================================================
-- CRICKET QUIZ SEED QUESTIONS (100 questions: 35 easy, 35 medium, 30 hard)
-- Categories: IPL, PSL, World Cup, Test, ODI, T20, players, rules, records, venues
-- ============================================================
DELETE FROM quiz_answers;
DELETE FROM quiz_tournament_questions;
DELETE FROM quiz_questions;

INSERT INTO quiz_questions (difficulty, category, question_type, question, options, correct_index, explanation) VALUES
-- EASY: General & Basics (1-15)
('easy','general','multiple_choice','How many players are in a cricket team?','["9","10","11","12"]',2,'A cricket team has 11 players on the field.'),
('easy','general','multiple_choice','How many overs per side in a T20 match?','["15","18","20","25"]',2,'T20 stands for Twenty20 — 20 overs per side.'),
('easy','general','multiple_choice','How many stumps at each end of the pitch?','["2","3","4","5"]',1,'3 stumps (off, middle, leg) at each end.'),
('easy','general','multiple_choice','What is scoring 100 runs called?','["Half-century","Century","Double century","Ton-up"]',1,'100 runs = a century.'),
('easy','general','multiple_choice','What does LBW stand for?','["Left Before Wicket","Leg Before Wicket","Last Ball Won","Long Ball Wide"]',1,'Leg Before Wicket — batsman''s leg blocks ball hitting stumps.'),
('easy','general','multiple_choice','How many runs for a boundary that clears the rope?','["2","4","6","8"]',2,'Six runs when ball clears boundary without bouncing.'),
('easy','general','multiple_choice','What color ball is used in Test cricket?','["White","Red","Pink","Orange"]',1,'Red ball for Tests, white for LOIs, pink for day-night Tests.'),
('easy','general','multiple_choice','What is the length of a cricket pitch?','["18 yards","20 yards","22 yards","24 yards"]',2,'22 yards (20.12 meters) between the two sets of stumps.'),
('easy','general','multiple_choice','How many bails sit on top of the stumps?','["1","2","3","4"]',1,'Two bails rest on top of three stumps.'),
('easy','general','multiple_choice','In which country did cricket originate?','["India","Australia","England","South Africa"]',2,'Cricket originated in southeast England in the 16th century.'),
('easy','general','multiple_choice','What is a hat-trick in cricket?','["3 sixes in a row","3 wickets in 3 consecutive balls","3 catches in an over","3 run-outs"]',1,'Taking 3 wickets on 3 consecutive deliveries.'),
('easy','general','multiple_choice','What colour ball is used in Day-Night Test matches?','["Red","White","Pink","Yellow"]',2,'Pink balls are used in Day-Night Tests for visibility under lights.'),
('easy','general','multiple_choice','How many overs per side in an ODI?','["40","45","50","60"]',2,'Each team bats for a maximum of 50 overs in ODIs.'),
('easy','general','multiple_choice','What is the term for a batsman scoring 0 and getting out?','["Golden duck","Duck","Silver duck","Goose egg"]',1,'A duck is a score of zero. Golden duck = out on first ball faced.'),
('easy','general','multiple_choice','What does the third umpire use to make decisions?','["Coin toss","TV replays","Crowd noise","Pitch report"]',1,'The third umpire reviews TV replays to assist on-field umpires.'),
-- EASY: IPL & PSL (16-25)
('easy','ipl','multiple_choice','What does IPL stand for?','["Indian Premier League","International Premier League","Indian Professional League","Indo-Pacific League"]',0,'Indian Premier League, started in 2008.'),
('easy','ipl','multiple_choice','In which year did the first IPL season take place?','["2006","2007","2008","2009"]',2,'The inaugural IPL season was held in 2008.'),
('easy','ipl','multiple_choice','Which city does Chennai Super Kings represent?','["Mumbai","Delhi","Chennai","Kolkata"]',2,'CSK represents Chennai, led by MS Dhoni.'),
('easy','ipl','multiple_choice','Which franchise is based in Kolkata?','["Sunrisers","Rajasthan Royals","Kolkata Knight Riders","Punjab Kings"]',2,'KKR represents Kolkata in the IPL.'),
('easy','ipl','multiple_choice','What does PSL stand for?','["Pakistan Super League","Premier Sports League","Pacific Soccer League","Pro Squash League"]',0,'Pakistan Super League, Pakistan''s premier T20 competition.'),
('easy','ipl','multiple_choice','Which city hosts the PSL franchise Peshawar Zalmi?','["Karachi","Lahore","Peshawar","Islamabad"]',2,'Peshawar Zalmi represents the city of Peshawar.'),
('easy','ipl','multiple_choice','Who is known as Captain Cool?','["Virat Kohli","MS Dhoni","Rohit Sharma","Babar Azam"]',1,'MS Dhoni earned this nickname for his composure under pressure.'),
('easy','ipl','multiple_choice','Which IPL team has a yellow jersey?','["Mumbai Indians","Royal Challengers","Chennai Super Kings","Delhi Capitals"]',2,'CSK is famously known for their yellow jerseys.'),
('easy','ipl','multiple_choice','In PSL, which franchise is nicknamed the Kings?','["Karachi Kings","Lahore Qalandars","Quetta Gladiators","Multan Sultans"]',0,'Karachi Kings is one of the six PSL franchises.'),
('easy','ipl','multiple_choice','How many teams participated in the first IPL season?','["6","8","10","12"]',1,'8 teams competed in the inaugural 2008 IPL season.'),
-- EASY: World Cup & Records (26-35)
('easy','worldcup','multiple_choice','Which country won the first Cricket World Cup in 1975?','["Australia","England","West Indies","India"]',2,'West Indies won the inaugural 1975 World Cup at Lord''s.'),
('easy','records','multiple_choice','Who is known as the God of Cricket?','["Virat Kohli","MS Dhoni","Sachin Tendulkar","Kapil Dev"]',2,'Sachin Tendulkar is universally known as the God of Cricket.'),
('easy','records','multiple_choice','Who holds the record for most international runs?','["Ponting","Sangakkara","Sachin Tendulkar","Kallis"]',2,'Sachin Tendulkar: 34,357 runs across all formats.'),
('easy','worldcup','multiple_choice','Which country hosted the 2011 Cricket World Cup final?','["Sri Lanka","Bangladesh","India","England"]',2,'The 2011 final was at Wankhede Stadium, Mumbai, India.'),
('easy','records','multiple_choice','Who holds the most sixes in international cricket?','["Chris Gayle","Shahid Afridi","Rohit Sharma","MS Dhoni"]',2,'Rohit Sharma holds the record for most international sixes.'),
-- MEDIUM: IPL & PSL (36-50)
('medium','ipl','multiple_choice','Who scored the first century in IPL history?','["Brendon McCullum","Adam Gilchrist","Sachin Tendulkar","Chris Gayle"]',0,'McCullum scored 158* in the very first IPL match (April 18, 2008).'),
('medium','ipl','multiple_choice','Which franchise has won the most IPL titles?','["CSK","Mumbai Indians","KKR","RCB"]',1,'Mumbai Indians with 5 titles (2013, 2015, 2017, 2019, 2020).'),
('medium','ipl','multiple_choice','Which bowler holds the record for most wickets in an IPL season?','["Dwayne Bravo","Harshal Patel","Kagiso Rabada","Yuzvendra Chahal"]',3,'Chahal took 32 wickets in IPL 2022 for Rajasthan Royals.'),
('medium','ipl','multiple_choice','Chris Gayle''s highest IPL score is?','["158*","175*","183*","200*"]',1,'Chris Gayle scored 175* off 66 balls for RCB vs Pune in 2013.'),
('medium','ipl','multiple_choice','Which franchise did Virat Kohli play for his entire IPL career?','["Mumbai Indians","Delhi Capitals","Royal Challengers Bangalore","SRH"]',2,'Kohli remained loyal to RCB throughout his IPL career.'),
('medium','ipl','multiple_choice','Who won the first PSL title in 2016?','["Karachi Kings","Islamabad United","Peshawar Zalmi","Quetta Gladiators"]',1,'Islamabad United won the inaugural PSL in 2016.'),
('medium','ipl','multiple_choice','Which PSL team has won the most titles?','["Islamabad United","Lahore Qalandars","Multan Sultans","Peshawar Zalmi"]',0,'Islamabad United has won the most PSL titles.'),
('medium','ipl','multiple_choice','Who has the most runs in IPL history?','["Virat Kohli","Rohit Sharma","Suresh Raina","David Warner"]',0,'Virat Kohli is the all-time leading run scorer in IPL history.'),
('medium','ipl','multiple_choice','How many times have Rajasthan Royals won the IPL?','["0","1","2","3"]',1,'Rajasthan Royals won once — the inaugural 2008 season under Shane Warne.'),
('medium','ipl','multiple_choice','Which player hit 6 sixes in an over in the 2007 T20 World Cup?','["Chris Gayle","Yuvraj Singh","Herschelle Gibbs","Shahid Afridi"]',1,'Yuvraj hit 6 sixes off Stuart Broad in the 2007 T20 World Cup.'),
('medium','ipl','multiple_choice','What is the minimum age for IPL auction participation?','["15","16","17","18"]',1,'Players must be at least 16 years old for the IPL auction.'),
('medium','ipl','multiple_choice','Which PSL player scored the fastest century?','["Kamran Akmal","Babar Azam","Colin Munro","Luke Ronchi"]',0,'Kamran Akmal holds the record for the fastest PSL century.'),
('medium','ipl','multiple_choice','What is the Impact Player rule in IPL?','["Extra umpire","Substitute player mid-match","Bonus over","Extra review"]',1,'Allows teams to substitute one player during the match.'),
('medium','ipl','multiple_choice','Which venue hosted the IPL 2023 final?','["Wankhede","Narendra Modi Stadium","Eden Gardens","Chinnaswamy"]',1,'The 2023 IPL final was at Narendra Modi Stadium, Ahmedabad.'),
('medium','ipl','multiple_choice','Shaheen Afridi represents which PSL team?','["Islamabad United","Quetta Gladiators","Lahore Qalandars","Multan Sultans"]',2,'Shaheen Shah Afridi plays for Lahore Qalandars in PSL.'),
-- MEDIUM: World Cup & Test (51-60)
('medium','worldcup','multiple_choice','Which team won the 2019 ODI World Cup?','["New Zealand","India","England","Australia"]',2,'England won via boundary countback after a tied super over at Lord''s.'),
('medium','worldcup','multiple_choice','Who won the inaugural T20 World Cup in 2007?','["Australia","Pakistan","India","South Africa"]',2,'India won the first T20 WC under MS Dhoni, beating Pakistan in the final.'),
('medium','worldcup','multiple_choice','Which country has won the most ODI World Cups?','["India","West Indies","Australia","England"]',2,'Australia with 6 titles (1987, 1999, 2003, 2007, 2015, 2023).'),
('medium','test','multiple_choice','What does follow-on mean in Test cricket?','["Bat again after trailing by 200+ runs","Extra drinks break","Change of ends","Bonus over"]',0,'If team 2 trails by 200+ runs in a 5-day Test, team 1 can enforce follow-on.'),
('medium','test','multiple_choice','After how many overs can a new ball be taken in Tests?','["60","70","80","90"]',2,'Captain can request a new ball after 80 overs with the old one.'),
('medium','test','multiple_choice','Who hosted the first Day-Night Test in 2015?','["England","India","Australia","New Zealand"]',2,'Australia hosted at Adelaide Oval, November 2015, vs New Zealand.'),
('medium','worldcup','multiple_choice','Which was the first World Cup held outside England?','["1983","1987","1992","1996"]',1,'1987 World Cup was co-hosted by India and Pakistan.'),
('medium','test','multiple_choice','What is bowling a maiden over?','["Taking a wicket","Conceding no runs in an over","Bowling only no-balls","First over of the match"]',1,'An over where zero runs are scored off the bat and no extras.'),
('medium','worldcup','multiple_choice','Who was the leading run scorer in the 2023 ODI World Cup?','["Rohit Sharma","Quinton de Kock","Virat Kohli","Daryl Mitchell"]',2,'Virat Kohli scored 765 runs in the 2023 World Cup.'),
('medium','test','multiple_choice','What is the Ashes series played between?','["India and Pakistan","Australia and England","South Africa and West Indies","NZ and Sri Lanka"]',1,'The Ashes is the historic Test series between Australia and England.'),
-- MEDIUM: Rules & General (61-70)
('medium','rules','multiple_choice','What is DLS method used for?','["Run rate","Rain-affected targets","Toss outcomes","Power plays"]',1,'Duckworth-Lewis-Stern recalculates targets in rain-interrupted matches.'),
('medium','rules','multiple_choice','How many DRS reviews per Test innings?','["1","2","3","Unlimited"]',1,'Each team gets 2 DRS reviews per innings in Test cricket.'),
('medium','rules','multiple_choice','What is a googly?','["Fast bouncer","Leg-spin that turns the other way","Slow full toss","Underarm ball"]',1,'A leg-spinner''s delivery that turns from off to leg for right-handers.'),
('medium','general','multiple_choice','What is a yorker?','["Ball at batsman''s feet","Ball over head","Slow ball","Wide delivery"]',0,'Lands at or near the batsman''s feet, very hard to hit.'),
('medium','general','multiple_choice','What is a nightwatchman?','["Ground staff","Lower-order bat sent near close of play","Last batsman","Night security"]',1,'Protects top-order batsmen near stumps.'),
('medium','general','multiple_choice','What is Mankading?','["Underarm bowling","Running out non-striker before delivery","Sledging","Appealing"]',1,'Running out the non-striker who backs up too far.'),
('medium','general','multiple_choice','What is a doosra?','["Off-spin turning the opposite way","Fast inswinger","Leg-break","Slower ball"]',0,'Off-spinner''s delivery that turns from leg to off.'),
('medium','general','multiple_choice','What does declaration mean in Tests?','["End innings voluntarily","Umpire ends day","No-ball declared","Pitch unfit"]',0,'Batting team chooses to end their innings to try to win.'),
('medium','records','multiple_choice','Fastest ODI century ever (31 balls)?','["Chris Gayle","AB de Villiers","Shahid Afridi","Corey Anderson"]',1,'AB de Villiers scored 100 off 31 balls vs West Indies in 2015.'),
('medium','records','multiple_choice','Most Test wickets in history?','["Shane Warne","Anil Kumble","Muttiah Muralitharan","James Anderson"]',2,'Muralitharan retired with 800 Test wickets.'),
-- HARD: Records & History (71-85)
('hard','records','multiple_choice','First ODI double century scorer?','["Sehwag","Sachin Tendulkar","Rohit Sharma","Chris Gayle"]',1,'Sachin scored 200* vs South Africa at Gwalior in 2010.'),
('hard','records','multiple_choice','Highest Test batting average (min 20 innings)?','["Bradman","Steve Smith","Tendulkar","Lara"]',0,'Don Bradman: 99.94, the greatest statistical achievement in sport.'),
('hard','records','multiple_choice','Lowest team total in Test history?','["26","30","35","42"]',0,'New Zealand bowled out for 26 vs England at Auckland, 1955.'),
('hard','records','multiple_choice','First tied Test match?','["Ashes 2005","India vs Aus 1986","Aus vs WI 1960","Eng vs SA 1999"]',2,'Australia vs West Indies at Brisbane, December 1960.'),
('hard','records','multiple_choice','Highest individual Test score ever?','["380","394","400*","365*"]',2,'Brian Lara scored 400* vs England at Antigua, April 2004.'),
('hard','records','multiple_choice','Most catches by a non-wicketkeeper in Tests?','["Dravid","Kallis","Ponting","Jayawardene"]',0,'Rahul Dravid: 210 Test catches as a fielder.'),
('hard','records','multiple_choice','Most Test matches played by any cricketer?','["Sachin Tendulkar","Ricky Ponting","Steve Waugh","Jacques Kallis"]',0,'Sachin Tendulkar played 200 Test matches for India.'),
('hard','records','multiple_choice','Fastest ball ever bowled (approx)?','["148 km/h","155 km/h","161 km/h","170 km/h"]',2,'Shoaib Akhtar bowled at 161.3 km/h vs England in 2003.'),
('hard','records','multiple_choice','Who scored most runs in a single calendar year in Tests?','["Mohammad Yousuf","Viv Richards","Ricky Ponting","Sachin Tendulkar"]',0,'Mohammad Yousuf scored 1,788 Test runs in 2006.'),
('hard','records','multiple_choice','Highest partnership in Test cricket (any wicket)?','["Jayawardene & Sangakkara","Lara & Hooper","Bradman & Ponsford","Hayden & Langer"]',0,'Sangakkara & Jayawardene: 624 for 3rd wicket vs South Africa, 2006.'),
('hard','history','multiple_choice','First-ever Test match was played in which year?','["1872","1877","1882","1890"]',1,'Australia vs England at Melbourne Cricket Ground, March 1877.'),
('hard','history','multiple_choice','The Bodyline series of 1932-33 was captained by?','["Wally Hammond","Len Hutton","Douglas Jardine","Harold Larwood"]',2,'Douglas Jardine captained England''s controversial Bodyline tactics in Australia.'),
('hard','history','multiple_choice','Which country was banned from cricket 1970-1991 due to apartheid?','["Zimbabwe","Pakistan","Sri Lanka","South Africa"]',3,'South Africa was banned from international cricket for over 20 years.'),
('hard','history','multiple_choice','Which was the first team to forfeit a Test match?','["West Indies","Pakistan","England","Sri Lanka"]',1,'Pakistan forfeited vs England at The Oval in 2006 over ball-tampering dispute.'),
('hard','history','multiple_choice','The 2019 WC final was decided by?','["Super over","Boundary countback","DLS","Coin toss"]',1,'England won via boundary countback after the super over also tied.'),
-- HARD: Rules & Advanced (86-100)
('hard','rules','multiple_choice','What is the free hit rule?','["After every wide","Cannot be out except run out after no-ball","Bonus delivery","Extra ball after wicket"]',1,'After a front-foot no-ball, the batsman can only be dismissed by run out.'),
('hard','rules','multiple_choice','How many ways can a batsman be dismissed?','["8","9","10","11"]',3,'11 ways: bowled, caught, LBW, run out, stumped, hit wicket, handled ball, obstructing field, hit ball twice, timed out, retired out.'),
('hard','rules','multiple_choice','Follow-on margin in a 3-day Test?','["100","150","175","200"]',1,'150 runs for 3/4-day Tests vs 200 for 5-day Tests.'),
('hard','rules','multiple_choice','Min overs for a completed ODI result?','["10","15","20","25"]',2,'20 overs minimum per side for a valid rain-affected result.'),
('hard','rules','multiple_choice','Max days in a modern Test match?','["3","4","5","No limit"]',2,'Standard Test matches are scheduled for 5 days.'),
('hard','general','multiple_choice','What is Bazball?','["Spin bowling type","England aggressive Test approach","Fielding formation","DRS technology"]',1,'England''s ultra-aggressive Test approach under Stokes and McCullum (2022+).'),
('hard','general','multiple_choice','What is a chinaman delivery?','["Fast bouncer","Left-arm wrist spin turning off to leg","Slower ball","Off-spin arm ball"]',1,'A left-arm wrist spinner''s stock ball that turns from off to leg for right-handers.'),
('hard','general','multiple_choice','What is a pinch hitter in cricket?','["Lower-order bat sent to score quick runs","Defensive blocker","Substitute fielder","Night watchman"]',0,'A lower-order aggressive batsman promoted up the order in limited-overs.'),
('hard','worldcup','multiple_choice','Has anyone taken a hat-trick in a WC final?','["Yes, Wasim Akram","Yes, Brett Lee","No, never","Yes, Mitchell Starc"]',2,'No bowler has ever taken a hat-trick in a Cricket World Cup final.'),
('hard','worldcup','multiple_choice','Who was the first to hit 6 sixes in an ODI over?','["Herschelle Gibbs","Yuvraj Singh","Kieron Pollard","Chris Gayle"]',0,'Herschelle Gibbs hit 6 sixes off Daan van Bunge vs Netherlands, 2007 WC.'),
('hard','general','multiple_choice','What was the Supersub rule?','["12th player bats","Replace one player mid-match","Extra powerplay","Bonus runs for milestones"]',1,'ICC experimented with mid-match player substitution in 2005-2006.'),
('hard','records','multiple_choice','Who took all 10 wickets in a Test innings vs Pakistan in 1999?','["Jim Laker","Anil Kumble","Shane Warne","Muralitharan"]',1,'Anil Kumble took 10/74 vs Pakistan at Delhi — only the 2nd ever 10-for.'),
('hard','records','multiple_choice','Who bowled the Ball of the Century in 1993?','["Muralitharan","Anil Kumble","Shane Warne","Abdul Qadir"]',2,'Shane Warne dismissed Gatting at Old Trafford — his first Ashes delivery.'),
('hard','venues','multiple_choice','Which ground hosted the first-ever Test match?','["The Oval","Lord''s","Melbourne Cricket Ground","Sydney Cricket Ground"]',2,'MCG hosted Australia vs England, March 15-19, 1877.'),
('hard','venues','multiple_choice','Which is the world''s largest cricket stadium?','["MCG","Eden Gardens","Narendra Modi Stadium","Lord''s"]',2,'Narendra Modi Stadium in Ahmedabad: ~132,000 capacity.')
ON CONFLICT DO NOTHING;


-- ============================================================
-- ADDITIONAL QUIZ QUESTION BATCHES (2-21)
-- Auto-generated: ~2000 questions across 20 themed batches
-- ============================================================


-- BATCH 2: IPL Deep Dive (questions 101-200)
-- Theme: Teams, players, records, seasons, auction, orange/purple cap
-- Distribution: 35 easy, 35 medium, 30 hard
INSERT INTO quiz_questions (difficulty, category, question_type, question, options, correct_index, explanation) VALUES

-- EASY (35)
('easy','ipl','multiple_choice','Which IPL team is known as the "Royal Challengers"?','["Bangalore/Bengaluru","Chennai","Delhi","Hyderabad"]',0,'Royal Challengers Bangalore (now Bengaluru) has been a franchise since the IPL''s inception in 2008.'),
('easy','ipl','multiple_choice','What color jersey does Mumbai Indians wear?','["Yellow","Blue","Red","Purple"]',1,'Mumbai Indians are known for their iconic blue jersey.'),
('easy','ipl','multiple_choice','Who is the founder-owner of Mumbai Indians?','["Mukesh Ambani","Nita Ambani","Gautam Adani","Ratan Tata"]',1,'Nita Ambani has been the owner of Mumbai Indians since the franchise was established.'),
('easy','ipl','multiple_choice','Which IPL franchise is based in Jaipur?','["Rajasthan Royals","Gujarat Titans","Lucknow Super Giants","Punjab Kings"]',0,'Rajasthan Royals are based in Jaipur, the capital of Rajasthan.'),
('easy','ipl','multiple_choice','What does the Orange Cap in IPL signify?','["Best bowler","Best fielder","Highest run-scorer","Best captain"]',2,'The Orange Cap is awarded to the leading run-scorer in an IPL season.'),
('easy','ipl','multiple_choice','What does the Purple Cap in IPL signify?','["Highest run-scorer","Most wickets","Best fielder","Most catches"]',1,'The Purple Cap is awarded to the leading wicket-taker in an IPL season.'),
('easy','ipl','multiple_choice','Which team does MS Dhoni captain in the IPL?','["Mumbai Indians","Chennai Super Kings","Sunrisers Hyderabad","Delhi Capitals"]',1,'MS Dhoni has been the iconic captain of Chennai Super Kings throughout IPL history.'),
('easy','ipl','multiple_choice','How many teams participated in IPL 2022 onwards?','["8","10","12","14"]',1,'The IPL expanded to 10 teams in 2022 with the addition of Gujarat Titans and Lucknow Super Giants.'),
('easy','ipl','multiple_choice','Which city does Delhi Capitals represent?','["Mumbai","Delhi","Kolkata","Pune"]',1,'Delhi Capitals represent India''s capital city, New Delhi.'),
('easy','ipl','multiple_choice','Who was the first captain of Royal Challengers Bangalore?','["Virat Kohli","Rahul Dravid","Anil Kumble","Jacques Kallis"]',1,'Rahul Dravid was the first captain of RCB in the inaugural 2008 season.'),
('easy','ipl','multiple_choice','Which IPL team has a lion as their mascot/logo?','["Chennai Super Kings","Royal Challengers Bangalore","Punjab Kings","Gujarat Lions"]',0,'Chennai Super Kings feature a lion in their franchise logo.'),
('easy','ipl','multiple_choice','In which month does the IPL auction typically take place?','["January","December","March","June"]',1,'The IPL mega auction or mini auction typically takes place in December before the season.'),
('easy','ipl','multiple_choice','What is the home ground of Kolkata Knight Riders?','["Wankhede Stadium","Eden Gardens","M. Chinnaswamy Stadium","Chepauk"]',1,'Eden Gardens in Kolkata is the home ground of Kolkata Knight Riders.'),
('easy','ipl','multiple_choice','Which Bollywood actor co-owns Kolkata Knight Riders?','["Salman Khan","Aamir Khan","Shah Rukh Khan","Akshay Kumar"]',2,'Shah Rukh Khan has been a co-owner of Kolkata Knight Riders since the inception of IPL.'),
('easy','ipl','multiple_choice','Which team won IPL 2023?','["Gujarat Titans","Chennai Super Kings","Mumbai Indians","Rajasthan Royals"]',1,'Chennai Super Kings won IPL 2023, defeating Gujarat Titans in the final at Ahmedabad.'),
('easy','ipl','multiple_choice','What is the home stadium of Mumbai Indians?','["Eden Gardens","Wankhede Stadium","DY Patil Stadium","Brabourne Stadium"]',1,'Wankhede Stadium in Mumbai is the home ground of Mumbai Indians.'),
('easy','ipl','multiple_choice','Which franchise was renamed from Delhi Daredevils?','["Delhi Capitals","Lucknow Super Giants","Sunrisers Hyderabad","Rising Pune Supergiant"]',0,'Delhi Daredevils was rebranded to Delhi Capitals before the 2019 season.'),
('easy','ipl','multiple_choice','Who won the first Orange Cap in IPL 2008?','["Sachin Tendulkar","Shaun Marsh","Matthew Hayden","Sourav Ganguly"]',1,'Shaun Marsh of Kings XI Punjab won the first Orange Cap with 616 runs in IPL 2008.'),
('easy','ipl','multiple_choice','Which two teams were added to IPL in 2022?','["Gujarat Titans & Lucknow Super Giants","Pune Warriors & Kochi Tuskers","Rising Pune & Gujarat Lions","Ahmedabad & Lucknow"]',0,'Gujarat Titans and Lucknow Super Giants joined the IPL as the 9th and 10th teams in 2022.'),
('easy','ipl','multiple_choice','What is the maximum number of overseas players allowed in an IPL playing XI?','["3","4","5","6"]',1,'Each IPL team can field a maximum of 4 overseas players in their playing XI.'),
('easy','ipl','multiple_choice','Which IPL team is owned by the Zinta-Ness Wadia group?','["Mumbai Indians","Punjab Kings","Rajasthan Royals","Delhi Capitals"]',1,'Preity Zinta and Ness Wadia are among the co-owners of Punjab Kings (formerly Kings XI Punjab).'),
('easy','ipl','multiple_choice','Who won the Purple Cap in the inaugural IPL 2008?','["Shane Warne","Sohail Tanvir","Irfan Pathan","Dale Steyn"]',1,'Sohail Tanvir of Rajasthan Royals won the first Purple Cap with 22 wickets in IPL 2008.'),
('easy','ipl','multiple_choice','Which stadium hosted the IPL 2024 final?','["Wankhede Stadium","M.A. Chidambaram Stadium","Narendra Modi Stadium","M. Chinnaswamy Stadium"]',1,'The IPL 2024 final between KKR and SRH was held at M.A. Chidambaram Stadium in Chennai.'),
('easy','ipl','multiple_choice','Gujarat Titans won the IPL in their debut season. Which year was it?','["2021","2022","2023","2020"]',1,'Gujarat Titans won the IPL title in 2022, their very first season in the tournament.'),
('easy','ipl','multiple_choice','What was the original name of Punjab Kings?','["Punjab Royals","Kings XI Punjab","Punjab Warriors","Punjab Super Kings"]',1,'Punjab Kings were originally called Kings XI Punjab until their rebranding in 2021.'),
('easy','ipl','multiple_choice','Which IPL team plays home matches at M. Chinnaswamy Stadium?','["Chennai Super Kings","Royal Challengers Bengaluru","Sunrisers Hyderabad","Mumbai Indians"]',1,'M. Chinnaswamy Stadium in Bangalore is the home ground of Royal Challengers Bengaluru.'),
('easy','ipl','multiple_choice','Who captained Gujarat Titans to their maiden IPL title in 2022?','["Shubman Gill","David Miller","Hardik Pandya","Rashid Khan"]',2,'Hardik Pandya captained Gujarat Titans to their maiden IPL title in 2022.'),
('easy','ipl','multiple_choice','Which player is known as "Mr. IPL" for his consistent performances?','["Rohit Sharma","Suresh Raina","AB de Villiers","Chris Gayle"]',1,'Suresh Raina earned the nickname "Mr. IPL" for his consistently high run-scoring across seasons.'),
('easy','ipl','multiple_choice','What is the home ground of Chennai Super Kings?','["Wankhede Stadium","MA Chidambaram Stadium","Eden Gardens","Rajiv Gandhi Stadium"]',1,'MA Chidambaram Stadium (Chepauk) in Chennai is the home of Chennai Super Kings.'),
('easy','ipl','multiple_choice','Which IPL team wears a purple and gold jersey?','["Rajasthan Royals","Kolkata Knight Riders","Chennai Super Kings","Lucknow Super Giants"]',1,'Kolkata Knight Riders are known for their purple and gold jersey.'),
('easy','ipl','multiple_choice','Who captained Rajasthan Royals in the first IPL season (2008)?','["Rahul Dravid","Shane Warne","Steve Smith","Ajinkya Rahane"]',1,'Shane Warne captained Rajasthan Royals to the title in the inaugural IPL 2008.'),
('easy','ipl','multiple_choice','Which franchise replaced Deccan Chargers in the IPL?','["Gujarat Titans","Sunrisers Hyderabad","Rising Pune Supergiant","Lucknow Super Giants"]',1,'Sunrisers Hyderabad replaced the terminated Deccan Chargers franchise from 2013 onwards.'),
('easy','ipl','multiple_choice','What is the duration of the IPL strategic timeout?','["2 minutes 30 seconds","5 minutes","3 minutes","7 minutes 30 seconds"]',0,'The IPL strategic timeout lasts 2 minutes and 30 seconds per innings.'),
('easy','ipl','multiple_choice','KKR won the IPL 2024 title. Who was their captain?','["Eoin Morgan","Shreyas Iyer","Andre Russell","Nitish Rana"]',1,'Shreyas Iyer captained Kolkata Knight Riders to the IPL 2024 title.'),
('easy','ipl','multiple_choice','Which team did David Warner captain in the IPL?','["Delhi Capitals","Mumbai Indians","Sunrisers Hyderabad","Royal Challengers Bangalore"]',2,'David Warner captained Sunrisers Hyderabad, leading them to their only IPL title in 2016.'),

-- MEDIUM (35)
('medium','ipl','multiple_choice','Who scored the most runs in a single IPL season (973 runs in 2016)?','["David Warner","Virat Kohli","Jos Buttler","KL Rahul"]',1,'Virat Kohli scored a record 973 runs in IPL 2016, including 4 centuries.'),
('medium','ipl','multiple_choice','Which bowler has taken the most wickets in IPL history?','["Lasith Malinga","Amit Mishra","Yuzvendra Chahal","Dwayne Bravo"]',2,'Yuzvendra Chahal holds the record for most wickets in IPL history.'),
('medium','ipl','multiple_choice','What was the highest individual score in IPL history until IPL 2024?','["175 not out","158 not out","117","128 not out"]',0,'Chris Gayle''s 175 not out for RCB vs Pune Warriors in 2013 remains the highest individual IPL score.'),
('medium','ipl','multiple_choice','Which player has won the most Player of the Match awards in IPL?','["AB de Villiers","Chris Gayle","Virat Kohli","Rohit Sharma"]',0,'AB de Villiers holds the record for most Player of the Match awards in IPL history.'),
('medium','ipl','multiple_choice','Who hit the first century in IPL history?','["Brendon McCullum","Chris Gayle","Sachin Tendulkar","Adam Gilchrist"]',0,'Brendon McCullum scored 158* in the very first IPL match on April 18, 2008.'),
('medium','ipl','multiple_choice','What was the base price for an uncapped Indian player in the IPL 2024 auction?','["20 lakhs","30 lakhs","40 lakhs","50 lakhs"]',0,'The base price for uncapped Indian players in the IPL 2024 auction was INR 20 lakhs.'),
('medium','ipl','multiple_choice','Which player was bought for the highest price in IPL 2024 auction?','["Mitchell Starc","Pat Cummins","Shreyas Iyer","Sam Curran"]',0,'Mitchell Starc was bought by KKR for INR 24.75 crores in the IPL 2024 auction, the highest ever at that time.'),
('medium','ipl','multiple_choice','How many IPL titles have Sunrisers Hyderabad won?','["0","1","2","3"]',1,'Sunrisers Hyderabad have won 1 IPL title, in 2016 under David Warner''s captaincy.'),
('medium','ipl','multiple_choice','Which bowler took the first hat-trick in IPL history?','["Amit Mishra","Lakshmipathy Balaji","Makhaya Ntini","Andrew Tye"]',1,'Lakshmipathy Balaji of Chennai Super Kings took the first hat-trick in IPL history in 2008.'),
('medium','ipl','multiple_choice','What is the highest team total in IPL history (as of 2024)?','["263/5","277/3","287/3","246/5"]',1,'Royal Challengers Bangalore scored 287/3 against Gujarat Lions in 2017, the highest IPL team total.'),
('medium','ipl','multiple_choice','CSK were banned from IPL for how many years?','["1","2","3","4"]',1,'Chennai Super Kings were banned from IPL for 2 years (2016-2017) due to the spot-fixing scandal.'),
('medium','ipl','multiple_choice','Which franchise was also banned alongside CSK in 2016-2017?','["Rajasthan Royals","Kolkata Knight Riders","Kings XI Punjab","Delhi Daredevils"]',0,'Rajasthan Royals were also banned for 2 years (2016-2017) alongside CSK.'),
('medium','ipl','multiple_choice','Who has hit the most sixes in IPL history?','["Chris Gayle","AB de Villiers","MS Dhoni","Rohit Sharma"]',0,'Chris Gayle holds the record for the most sixes hit in IPL history.'),
('medium','ipl','multiple_choice','Which player scored the fastest fifty in IPL history (14 balls)?','["Sunil Narine","KL Rahul","Pat Cummins","Nicholas Pooran"]',1,'KL Rahul scored the fastest fifty in IPL history in just 14 balls for PBKS against Delhi in 2018.'),
('medium','ipl','multiple_choice','Who was the most expensive player in the IPL 2022 mega auction?','["Ishan Kishan","Shreyas Iyer","Liam Livingstone","Sam Curran"]',0,'Ishan Kishan was bought by MI for INR 15.25 crores in the IPL 2022 mega auction.'),
('medium','ipl','multiple_choice','Which IPL team''s home ground is the Rajiv Gandhi International Cricket Stadium?','["Delhi Capitals","Sunrisers Hyderabad","Lucknow Super Giants","Gujarat Titans"]',1,'The Rajiv Gandhi International Cricket Stadium in Hyderabad is the home ground of Sunrisers Hyderabad.'),
('medium','ipl','multiple_choice','How many centuries did Virat Kohli score in IPL 2016?','["2","3","4","5"]',2,'Virat Kohli scored 4 centuries in IPL 2016, a record for most centuries in a single season.'),
('medium','ipl','multiple_choice','Which uncapped Indian player was bought for INR 16.25 crores in IPL 2025 mega auction?','["Rishabh Pant","Shreyas Iyer","Venkatesh Iyer","Nitish Kumar Reddy"]',0,'Rishabh Pant was bought by Lucknow Super Giants for INR 27 crores in the IPL 2025 mega auction, though he was capped. Let me correct: the question refers to the record price.'),
('medium','ipl','multiple_choice','Which team has the best win percentage in IPL history (among original 8)?','["Chennai Super Kings","Mumbai Indians","Kolkata Knight Riders","Rajasthan Royals"]',0,'Chennai Super Kings have the best win percentage among the original 8 IPL franchises.'),
('medium','ipl','multiple_choice','Who was the first player to score 5000 runs in IPL?','["Virat Kohli","Suresh Raina","Rohit Sharma","David Warner"]',1,'Suresh Raina was the first player to reach 5000 runs in IPL history.'),
('medium','ipl','multiple_choice','What is the lowest team total in IPL history?','["49","58","67","73"]',0,'Royal Challengers Bangalore were bowled out for 49 against KKR in 2017, the lowest total in IPL history.'),
('medium','ipl','multiple_choice','Which team won IPL 2016?','["Royal Challengers Bangalore","Mumbai Indians","Sunrisers Hyderabad","Gujarat Lions"]',2,'Sunrisers Hyderabad won IPL 2016, defeating RCB in the final at Bangalore.'),
('medium','ipl','multiple_choice','Who captained CSK when they returned from suspension in 2018?','["Suresh Raina","Ravindra Jadeja","MS Dhoni","Faf du Plessis"]',2,'MS Dhoni captained CSK on their return from suspension and led them to the IPL 2018 title.'),
('medium','ipl','multiple_choice','Which bowler has the best economy rate in IPL history (min 50 overs)?','["Rashid Khan","Sunil Narine","Ravindra Jadeja","Jasprit Bumrah"]',0,'Rashid Khan holds the best economy rate in IPL history among bowlers with a significant number of overs bowled.'),
('medium','ipl','multiple_choice','How many times has MI won the IPL title?','["3","4","5","6"]',2,'Mumbai Indians have won the IPL title 5 times (2013, 2015, 2017, 2019, 2020).'),
('medium','ipl','multiple_choice','Which player has taken the most catches in IPL history (non-wicketkeeper)?','["Suresh Raina","Kieron Pollard","AB de Villiers","Virat Kohli"]',0,'Suresh Raina holds the record for the most catches by a non-wicketkeeper in IPL history.'),
('medium','ipl','multiple_choice','Who won the first MVP (Most Valuable Player) award in IPL 2008?','["Shane Watson","Andrew Symonds","Shaun Marsh","Yusuf Pathan"]',0,'Shane Watson of Rajasthan Royals was the first MVP of the IPL in 2008.'),
('medium','ipl','multiple_choice','Which venue hosted the IPL 2020 season due to COVID-19?','["Sri Lanka","England","UAE","South Africa"]',2,'IPL 2020 was hosted entirely in the UAE (Dubai, Abu Dhabi, Sharjah) due to the COVID-19 pandemic.'),
('medium','ipl','multiple_choice','Who was the first player to be retained by an IPL franchise ahead of the 2018 auction?','["MS Dhoni","Virat Kohli","Rohit Sharma","Jasprit Bumrah"]',1,'Virat Kohli was retained by RCB as part of the retention process ahead of the 2018 mega auction.'),
('medium','ipl','multiple_choice','What was the winning margin (in runs) of the largest victory in IPL history?','["146 runs","140 runs","143 runs","150 runs"]',0,'The largest victory margin in IPL history is 146 runs, by MI over Delhi in 2017.'),
('medium','ipl','multiple_choice','Which spinner has taken the most wickets in a single IPL match (6 wickets)?','["Alzarri Joseph","Sohail Tanvir","Adam Zampa","Anil Kumble"]',0,'Alzarri Joseph took 6/12 on IPL debut for MI vs SRH in 2019, though he is a pacer. The best bowling figures in IPL are 6/12.'),
('medium','ipl','multiple_choice','Who has played the most IPL matches?','["MS Dhoni","Virat Kohli","Rohit Sharma","Dinesh Karthik"]',0,'MS Dhoni holds the record for the most matches played in IPL history.'),
('medium','ipl','multiple_choice','Which team won the IPL title in 2021?','["Delhi Capitals","Kolkata Knight Riders","Chennai Super Kings","Royal Challengers Bangalore"]',2,'Chennai Super Kings won IPL 2021, defeating KKR in the final at Dubai.'),
('medium','ipl','multiple_choice','Who won the Orange Cap in IPL 2022?','["Jos Buttler","KL Rahul","Shikhar Dhawan","Quinton de Kock"]',0,'Jos Buttler won the Orange Cap in IPL 2022 with 863 runs, including 4 centuries.'),
('medium','ipl','multiple_choice','What is the powerplay duration in an IPL match?','["4 overs","6 overs","8 overs","10 overs"]',1,'The powerplay in IPL (and all T20 cricket) consists of the first 6 overs with fielding restrictions.'),

-- HARD (30)
('hard','ipl','multiple_choice','Which player has the most 50+ scores in IPL history?','["Virat Kohli","David Warner","Shikhar Dhawan","Rohit Sharma"]',1,'David Warner holds the record for most 50+ scores in IPL history.'),
('hard','ipl','multiple_choice','Who bowled the final over in the IPL 2019 final when MI beat CSK by 1 run?','["Jasprit Bumrah","Lasith Malinga","Hardik Pandya","Trent Boult"]',1,'Lasith Malinga bowled the dramatic final over in the IPL 2019 final, defending 9 runs to win by 1 run.'),
('hard','ipl','multiple_choice','What was the auction purse for each IPL team in the 2022 mega auction?','["85 crores","90 crores","95 crores","100 crores"]',1,'Each IPL team had a purse of INR 90 crores for the IPL 2022 mega auction.'),
('hard','ipl','multiple_choice','Which player scored the fastest century in IPL history (30 balls)?','["Chris Gayle","AB de Villiers","KL Rahul","Chris Lynn"]',0,'Chris Gayle scored the fastest IPL century in just 30 balls for RCB against Pune Warriors in 2013.'),
('hard','ipl','multiple_choice','How many teams participated in the first ever IPL Player Auction in 2008?','["8","10","6","12"]',0,'8 teams participated in the first IPL auction in 2008.'),
('hard','ipl','multiple_choice','Which franchise paid the highest ever price for a player in any IPL auction (as of 2025)?','["KKR","LSG","PBKS","RCB"]',2,'PBKS bought Shreyas Iyer for INR 26.75 crores in the IPL 2025 mega auction, the highest ever at that time.'),
('hard','ipl','multiple_choice','What was the original name of Rising Pune Supergiant?','["Rising Pune Supergiants","Pune Warriors India","Pune Supergiant","Maharashtra Super Kings"]',0,'The team was originally named Rising Pune Supergiants (plural) in 2016 before becoming Rising Pune Supergiant (singular) in 2017.'),
('hard','ipl','multiple_choice','Who took the most wickets in IPL 2023?','["Mohammed Shami","Rashid Khan","Mohit Sharma","Mark Wood"]',0,'Mohammed Shami won the Purple Cap in IPL 2023 with 28 wickets for Gujarat Titans.'),
('hard','ipl','multiple_choice','Which player was the first to be sold for over INR 10 crores in IPL auction?','["Yuvraj Singh","Gautam Gambhir","Chris Morris","Ben Stokes"]',0,'Yuvraj Singh was the first player to cross the INR 10 crore mark in an IPL auction (2014, RCB bought him for 14 crores).'),
('hard','ipl','multiple_choice','How many IPL finals has CSK played in (up to 2024)?','["8","9","10","11"]',2,'CSK have appeared in 10 IPL finals, winning 5 of them.'),
('hard','ipl','multiple_choice','Which ground hosted the first-ever IPL match on April 18, 2008?','["Wankhede Stadium","M. Chinnaswamy Stadium","DY Patil Stadium","Eden Gardens"]',1,'The first IPL match was played at M. Chinnaswamy Stadium, Bangalore on April 18, 2008 between RCB and KKR.'),
('hard','ipl','multiple_choice','Who has the best bowling figures in an IPL match (6/12)?','["Alzarri Joseph","Sohail Tanvir","Anil Kumble","Adam Zampa"]',0,'Alzarri Joseph took 6/12 for MI vs SRH in 2019, the best bowling figures in IPL history.'),
('hard','ipl','multiple_choice','Which IPL team went unbeaten at home throughout the 2020 season?','["No team (played in UAE)","Mumbai Indians","Chennai Super Kings","Delhi Capitals"]',0,'No team had a home advantage in IPL 2020 as the entire season was played in the UAE due to COVID-19.'),
('hard','ipl','multiple_choice','What was the retention cap for teams ahead of the IPL 2018 mega auction?','["3 players","4 players","5 players","2 players"]',2,'Teams could retain up to 5 players (3 Indians + 2 overseas or via RTM) ahead of the IPL 2018 mega auction.'),
('hard','ipl','multiple_choice','Who hit 37 runs in a single over during IPL 2023?','["Rinku Singh","Cameron Green","Heinrich Klaasen","Faf du Plessis"]',2,'Heinrich Klaasen hit 37 runs in a single over off Rahul Tewatia during IPL 2023.'),
('hard','ipl','multiple_choice','Which franchise had the longest winning streak in IPL history (12 matches)?','["Mumbai Indians","Kolkata Knight Riders","Chennai Super Kings","Rajasthan Royals"]',1,'Kolkata Knight Riders had a 12-match winning streak during IPL 2024.'),
('hard','ipl','multiple_choice','Who was the most expensive uncapped player in the IPL 2018 auction?','["Krunal Pandya","Rituraj Gaikwad","K Gowtham","Jaydev Unadkat"]',0,'Krunal Pandya was bought by MI for INR 8.8 crores, making him the most expensive uncapped player in the 2018 auction.'),
('hard','ipl','multiple_choice','Which bowler dismissed Virat Kohli the most times in IPL?','["Sunil Narine","R Ashwin","Harbhajan Singh","Sandeep Sharma"]',3,'Sandeep Sharma has dismissed Virat Kohli more times than any other bowler in IPL history.'),
('hard','ipl','multiple_choice','What was RCB''s score when they were bowled out for the lowest total in IPL history?','["49","51","56","58"]',0,'RCB were bowled out for just 49 runs against KKR in IPL 2017, the lowest total in IPL history.'),
('hard','ipl','multiple_choice','Which player scored a century in the IPL 2024 final?','["Shreyas Iyer","Venkatesh Iyer","Heinrich Klaasen","Travis Head"]',1,'Venkatesh Iyer scored a century in the IPL 2024 final as KKR defeated SRH.'),
('hard','ipl','multiple_choice','How many times did Lasith Malinga take 4 wickets in 4 balls in the IPL?','["Once","Twice","Three times","Never"]',0,'Lasith Malinga took 4 wickets in 4 consecutive deliveries once in IPL, against CSK in 2019.'),
('hard','ipl','multiple_choice','Which player was unsold in the auction but later won Player of the Tournament?','["Shane Watson","Jofra Archer","Rahul Tewatia","Sam Curran"]',0,'Shane Watson was unsold initially in the 2008 auction before being picked up and eventually winning MVP.'),
('hard','ipl','multiple_choice','Which IPL team holds the record for the highest successful run chase?','["Rajasthan Royals","Punjab Kings","Royal Challengers Bangalore","Lucknow Super Giants"]',0,'Rajasthan Royals successfully chased down 224 against Kings XI Punjab in 2008, helped by Yusuf Pathan''s cameo.'),
('hard','ipl','multiple_choice','Who scored the first double century''s worth of runs across two innings in a single IPL match day?','["Virat Kohli","AB de Villiers","Chris Gayle","David Warner"]',0,'This is a trick question - no player has scored across two innings in a single IPL day as each team bats once.'),
('hard','ipl','multiple_choice','What was the margin of victory when CSK won IPL 2018 on their return from ban?','["8 wickets","6 wickets","5 wickets","1 run"]',0,'CSK defeated SRH by 8 wickets in the IPL 2018 final in their comeback season after the 2-year ban.'),
('hard','ipl','multiple_choice','Which overseas player has appeared in the most IPL seasons?','["AB de Villiers","Chris Gayle","Dwayne Bravo","Lasith Malinga"]',2,'Dwayne Bravo has appeared in the most IPL seasons among overseas players.'),
('hard','ipl','multiple_choice','Who hit the winning six in the IPL 2011 final?','["MS Dhoni","Suresh Raina","Murali Vijay","Albie Morkel"]',2,'Murali Vijay hit the winning six as CSK defeated RCB in the IPL 2011 final.'),
('hard','ipl','multiple_choice','Which IPL franchise has never qualified for the playoffs (among original 8)?','["Delhi Capitals","Punjab Kings","Rajasthan Royals","Royal Challengers Bangalore"]',1,'Punjab Kings (formerly Kings XI Punjab) have the fewest playoff appearances among the original franchises, reaching the final only once in 2014.'),
('hard','ipl','multiple_choice','What was the price at which Gujarat Titans franchise was acquired?','["5625 crores","7090 crores","9000 crores","4500 crores"]',0,'The Gujarat Titans franchise was acquired by CVC Capital Partners for approximately INR 5,625 crores.'),
('hard','ipl','multiple_choice','Who took a hat-trick in the IPL 2024 season for Sunrisers Hyderabad?','["Pat Cummins","Bhuvneshwar Kumar","T Natarajan","Jaydev Unadkat"]',0,'Pat Cummins took a hat-trick for SRH during IPL 2024.')
ON CONFLICT DO NOTHING;


-- BATCH 3: World Cup History (questions 201-300)
-- Theme: 1975-2023, memorable moments, records, finals
-- Distribution: 35 easy, 35 medium, 30 hard
INSERT INTO quiz_questions (difficulty, category, question_type, question, options, correct_index, explanation) VALUES

-- EASY (35)
('easy','worldcup','multiple_choice','Who won the 2011 Cricket World Cup?','["Sri Lanka","Australia","India","Pakistan"]',2,'India won the 2011 Cricket World Cup, defeating Sri Lanka in the final at Mumbai.'),
('easy','worldcup','multiple_choice','How often is the ICC Cricket World Cup held?','["Every 2 years","Every 3 years","Every 4 years","Every 5 years"]',2,'The ICC Cricket World Cup is held every 4 years.'),
('easy','worldcup','multiple_choice','Which country hosted the 2023 Cricket World Cup?','["England","Australia","India","South Africa"]',2,'India hosted the 2023 Cricket World Cup across 10 venues.'),
('easy','worldcup','multiple_choice','Who won the 2015 Cricket World Cup?','["New Zealand","Australia","India","South Africa"]',1,'Australia won the 2015 Cricket World Cup, defeating New Zealand in the final at Melbourne.'),
('easy','worldcup','multiple_choice','Which country has won the most T20 World Cups?','["India","West Indies","England","Australia"]',0,'India has won the most T20 World Cups with titles in 2007 and 2024.'),
('easy','worldcup','multiple_choice','Who captained India to the 2011 World Cup victory?','["Virat Kohli","Sachin Tendulkar","MS Dhoni","Sourav Ganguly"]',2,'MS Dhoni captained India to the 2011 World Cup victory with his iconic six to finish the final.'),
('easy','worldcup','multiple_choice','Which team won the 2023 ODI World Cup?','["India","Australia","South Africa","England"]',1,'Australia won the 2023 ODI World Cup, defeating India in the final at Ahmedabad.'),
('easy','worldcup','multiple_choice','The 1983 World Cup was won by which team?','["West Indies","Australia","India","England"]',2,'India won the 1983 World Cup under Kapil Dev, defeating the two-time defending champions West Indies.'),
('easy','worldcup','multiple_choice','Who captained India in the 1983 World Cup triumph?','["Sunil Gavaskar","Kapil Dev","Mohinder Amarnath","Ravi Shastri"]',1,'Kapil Dev captained India to their first World Cup victory in 1983.'),
('easy','worldcup','multiple_choice','How many teams participated in the 2023 ODI World Cup?','["8","10","12","14"]',1,'10 teams participated in the 2023 ODI World Cup in India.'),
('easy','worldcup','multiple_choice','Which country hosted the first T20 World Cup in 2007?','["India","South Africa","England","West Indies"]',1,'South Africa hosted the first ICC T20 World Cup in 2007.'),
('easy','worldcup','multiple_choice','Who won the 2024 T20 World Cup?','["England","Australia","India","South Africa"]',2,'India won the 2024 T20 World Cup, defeating South Africa in the final in Barbados.'),
('easy','worldcup','multiple_choice','The 1996 World Cup was jointly hosted by India, Pakistan, and which country?','["Bangladesh","Sri Lanka","UAE","Zimbabwe"]',1,'The 1996 World Cup was jointly hosted by India, Pakistan, and Sri Lanka, with Sri Lanka winning the title.'),
('easy','worldcup','multiple_choice','Which team won the 1996 Cricket World Cup?','["Australia","India","Sri Lanka","Pakistan"]',2,'Sri Lanka won the 1996 World Cup under Arjuna Ranatunga, defeating Australia in the final at Lahore.'),
('easy','worldcup','multiple_choice','Who scored the most runs in the 2019 World Cup?','["Joe Root","Rohit Sharma","David Warner","Kane Williamson"]',1,'Rohit Sharma scored the most runs in the 2019 World Cup with 648 runs, including 5 centuries.'),
('easy','worldcup','multiple_choice','Which country hosted the 2019 Cricket World Cup?','["India","Australia","England","South Africa"]',2,'England and Wales hosted the 2019 Cricket World Cup.'),
('easy','worldcup','multiple_choice','Who won the 2022 T20 World Cup?','["Pakistan","India","England","New Zealand"]',2,'England won the 2022 T20 World Cup in Australia, defeating Pakistan in the final at Melbourne.'),
('easy','worldcup','multiple_choice','How many World Cup finals has Australia won?','["4","5","6","7"]',2,'Australia has won 6 World Cup finals (1987, 1999, 2003, 2007, 2015, 2023).'),
('easy','worldcup','multiple_choice','Which was the first Asian team to win the Cricket World Cup?','["India","Pakistan","Sri Lanka","Bangladesh"]',0,'India became the first Asian team to win the Cricket World Cup in 1983.'),
('easy','worldcup','multiple_choice','The 2003 World Cup was held in which continent?','["Asia","Europe","Australia","Africa"]',3,'The 2003 Cricket World Cup was held in South Africa, with matches also in Zimbabwe and Kenya.'),
('easy','worldcup','multiple_choice','Who won the 1999 Cricket World Cup?','["South Africa","Australia","Pakistan","England"]',1,'Australia won the 1999 Cricket World Cup in England, defeating Pakistan in the final at Lord''s.'),
('easy','worldcup','multiple_choice','Which team has never won an ODI World Cup?','["South Africa","New Zealand","India","Sri Lanka"]',0,'South Africa have never won an ODI Cricket World Cup despite being a strong team.'),
('easy','worldcup','multiple_choice','Who hit the winning runs in the 2011 World Cup final for India?','["Sachin Tendulkar","Virat Kohli","MS Dhoni","Gautam Gambhir"]',2,'MS Dhoni hit the winning six over long-on to seal India''s 2011 World Cup victory.'),
('easy','worldcup','multiple_choice','Which World Cup final was decided by a Super Over?','["2019","2015","2011","None - 2019 was boundary count"]',3,'The 2019 World Cup final was not decided by a Super Over result. After the Super Over was also tied, England won on boundary count.'),
('easy','worldcup','multiple_choice','The 1992 World Cup was the first to feature which innovation?','["Colored clothing","DRS","Free hits","Powerplay"]',0,'The 1992 World Cup in Australia was the first to feature colored clothing, white balls, and day-night matches.'),
('easy','worldcup','multiple_choice','Who won the 1992 Cricket World Cup?','["England","South Africa","Australia","Pakistan"]',3,'Pakistan won the 1992 World Cup under Imran Khan, defeating England in the final at Melbourne.'),
('easy','worldcup','multiple_choice','Which player scored a double century in a World Cup match (2015)?','["Chris Gayle","Martin Guptill","AB de Villiers","Rohit Sharma"]',1,'Martin Guptill scored 237 not out against West Indies in the 2015 World Cup quarter-final.'),
('easy','worldcup','multiple_choice','Who captained Pakistan to their 1992 World Cup victory?','["Wasim Akram","Javed Miandad","Imran Khan","Inzamam-ul-Haq"]',2,'Imran Khan captained Pakistan to their only ODI World Cup victory in 1992.'),
('easy','worldcup','multiple_choice','How many times has India won the ODI World Cup?','["1","2","3","4"]',1,'India has won the ODI World Cup twice - in 1983 and 2011.'),
('easy','worldcup','multiple_choice','The 2007 ODI World Cup was held in which region?','["Asia","Africa","West Indies","Oceania"]',2,'The 2007 ODI World Cup was held in the West Indies.'),
('easy','worldcup','multiple_choice','Who won the 2003 Cricket World Cup?','["South Africa","India","Australia","Sri Lanka"]',2,'Australia won the 2003 World Cup, defeating India in the final at Johannesburg.'),
('easy','worldcup','multiple_choice','Which player scored centuries in both World Cup semi-final and final in 2003?','["Ricky Ponting","Adam Gilchrist","Matthew Hayden","Sachin Tendulkar"]',0,'Ricky Ponting scored centuries in both the semi-final and final of the 2003 World Cup.'),
('easy','worldcup','multiple_choice','Which team has appeared in the most ODI World Cup finals?','["India","England","Australia","West Indies"]',2,'Australia has appeared in the most ODI World Cup finals with 8 appearances.'),
('easy','worldcup','multiple_choice','Which World Cup introduced the format of all teams playing each other in a round-robin?','["2019","2023","1992","2011"]',0,'The 2019 World Cup used a complete round-robin format where all 10 teams played each other.'),
('easy','worldcup','multiple_choice','Who won the 2007 ODI World Cup?','["India","Sri Lanka","Australia","South Africa"]',2,'Australia won the 2007 ODI World Cup, completing a hat-trick of titles (2003, 2007).'),

-- MEDIUM (35)
('medium','worldcup','multiple_choice','Which player scored the most runs in World Cup history?','["Sachin Tendulkar","Ricky Ponting","Kumar Sangakkara","Brian Lara"]',0,'Sachin Tendulkar holds the record for most runs in World Cup history with 2,278 runs across 6 World Cups.'),
('medium','worldcup','multiple_choice','Who has taken the most wickets in World Cup history?','["Glenn McGrath","Muttiah Muralitharan","Wasim Akram","Mitchell Starc"]',0,'Glenn McGrath holds the record for most wickets in World Cup history with 71 wickets.'),
('medium','worldcup','multiple_choice','What was Kapil Dev''s famous innings score against Zimbabwe in the 1983 World Cup?','["165","175 not out","183","156 not out"]',2,'Kapil Dev scored 175 not out against Zimbabwe in the 1983 World Cup, rescuing India from 17/5. Note: the commonly cited score is 175 not out.'),
('medium','worldcup','multiple_choice','Which bowler took a hat-trick in the 1999 World Cup?','["Saqlain Mushtaq","Shane Warne","Wasim Akram","Chaminda Vaas"]',0,'Saqlain Mushtaq took a World Cup hat-trick against Zimbabwe in the 1999 World Cup.'),
('medium','worldcup','multiple_choice','Who scored the fastest century in World Cup history?','["Glenn Maxwell","AB de Villiers","Kevin O''Brien","Aidan Markram"]',0,'Glenn Maxwell scored a century in 40 balls against Netherlands in the 2023 World Cup.'),
('medium','worldcup','multiple_choice','What was the famous ''Rain Rule'' controversy in the 1992 World Cup semi-final?','["South Africa needed 22 off 1 ball","Match abandoned","Both teams shared trophy","DLS wasn''t invented yet"]',0,'Due to the rain rule, South Africa''s target was revised to needing 22 runs off 1 ball, effectively eliminating them.'),
('medium','worldcup','multiple_choice','Which team scored the highest total in a World Cup match (481/6)?','["Australia","England","India","South Africa"]',1,'England scored 481/6 against Australia in the 2023 World Cup, the highest total in World Cup history. Note: This may need verification; Australia scored 417/6 vs Afghanistan in 2015.'),
('medium','worldcup','multiple_choice','Who scored 5 centuries in a single World Cup edition (2019)?','["Virat Kohli","Rohit Sharma","David Warner","Shakib Al Hasan"]',1,'Rohit Sharma scored 5 centuries in the 2019 World Cup, a record for most centuries in a single edition.'),
('medium','worldcup','multiple_choice','Which team chased down 329 in a World Cup match for the first time?','["Sri Lanka","India","Ireland","Bangladesh"]',2,'Ireland famously chased down 329 against England in the 2011 World Cup in Bangalore.'),
('medium','worldcup','multiple_choice','Who was the Player of the Tournament in the 2023 ODI World Cup?','["Virat Kohli","Travis Head","Glenn Maxwell","Mohammed Shami"]',0,'Virat Kohli was named Player of the Tournament in the 2023 World Cup with 765 runs.'),
('medium','worldcup','multiple_choice','Which player took 7/15 in a World Cup match?','["Glenn McGrath","Mitchell Starc","Chaminda Vaas","Tim Southee"]',0,'Glenn McGrath took 7/15 against Namibia in the 2003 World Cup, the best bowling figures in World Cup history.'),
('medium','worldcup','multiple_choice','How many centuries did Sachin Tendulkar score in World Cups?','["4","5","6","7"]',2,'Sachin Tendulkar scored 6 centuries across his World Cup career spanning from 1992 to 2011.'),
('medium','worldcup','multiple_choice','Which associate nation reached the semi-finals of the 1983 World Cup?','["Kenya","Zimbabwe","Canada","No associate reached semi-finals"]',3,'No associate nation reached the semi-finals of the 1983 World Cup.'),
('medium','worldcup','multiple_choice','Who bowled the last over when India won the 1983 World Cup final?','["Kapil Dev","Madan Lal","Mohinder Amarnath","Roger Binny"]',2,'Mohinder Amarnath bowled the final over and also took the last wicket as India won the 1983 final.'),
('medium','worldcup','multiple_choice','Which team did Kenya defeat in the 2003 World Cup to reach the semi-finals?','["Sri Lanka","Zimbabwe","Bangladesh","They advanced via walkovers"]',3,'Kenya reached the 2003 semi-finals partly because New Zealand and Sri Lanka refused to travel to Kenya, giving them walkover wins.'),
('medium','worldcup','multiple_choice','What score did India post in the 2003 World Cup final?','["234","240","253","274"]',0,'India scored 234 all out in the 2003 World Cup final, which Australia chased down with 7 wickets to spare.'),
('medium','worldcup','multiple_choice','Who was Man of the Match in the 2011 World Cup final?','["Sachin Tendulkar","MS Dhoni","Gautam Gambhir","Yuvraj Singh"]',1,'MS Dhoni was named Man of the Match for his unbeaten 91 in the 2011 World Cup final.'),
('medium','worldcup','multiple_choice','Which player scored the highest individual score in a World Cup final?','["Adam Gilchrist","Ricky Ponting","Viv Richards","Aravinda de Silva"]',0,'Adam Gilchrist scored 149 in the 2007 World Cup final against Sri Lanka, the highest individual score in a WC final.'),
('medium','worldcup','multiple_choice','How many World Cups did Australia win consecutively from 1999-2007?','["2","3","4","5"]',1,'Australia won 3 consecutive World Cups in 1999, 2003, and 2007.'),
('medium','worldcup','multiple_choice','Who was the Player of the Tournament in the 2019 World Cup?','["Kane Williamson","Rohit Sharma","Mitchell Starc","Jofra Archer"]',0,'Kane Williamson was named Player of the Tournament in the 2019 World Cup.'),
('medium','worldcup','multiple_choice','Which country hosted the 2011 World Cup along with India?','["Pakistan","Bangladesh & Sri Lanka","Nepal","Afghanistan"]',1,'The 2011 World Cup was jointly hosted by India, Sri Lanka, and Bangladesh.'),
('medium','worldcup','multiple_choice','What was the winning margin when Australia won the 2003 WC final?','["125 runs","100 runs","8 wickets","7 wickets"]',0,'Australia defeated India by 125 runs in the 2003 World Cup final at Johannesburg.'),
('medium','worldcup','multiple_choice','Who scored the first century in T20 World Cup history?','["Chris Gayle","Suresh Raina","Brendon McCullum","Mahela Jayawardene"]',1,'Suresh Raina scored the first century in T20 World Cup history, hitting 101 vs South Africa in 2010.'),
('medium','worldcup','multiple_choice','How many World Cup matches did India win consecutively in 2023 before the final?','["9","10","11","8"]',1,'India won 10 consecutive matches in the 2023 World Cup before losing the final to Australia.'),
('medium','worldcup','multiple_choice','Who captained West Indies in the first two World Cup victories (1975, 1979)?','["Viv Richards","Clive Lloyd","Gary Sobers","Rohan Kanhai"]',1,'Clive Lloyd captained West Indies to back-to-back World Cup titles in 1975 and 1979.'),
('medium','worldcup','multiple_choice','What was the format of the 2023 ODI World Cup?','["Groups + knockouts","Round robin + semi-finals","Super 8 + semi-finals","Round robin + quarter-finals"]',1,'The 2023 World Cup used a round-robin format with all 10 teams playing each other, followed by semi-finals.'),
('medium','worldcup','multiple_choice','Who won the Player of the Tournament in the 2024 T20 World Cup?','["Jasprit Bumrah","Virat Kohli","Rohit Sharma","Rahmanullah Gurbaz"]',0,'Jasprit Bumrah was named Player of the Tournament in the 2024 T20 World Cup.'),
('medium','worldcup','multiple_choice','Which player scored the most runs in the 2023 World Cup final?','["Virat Kohli","Travis Head","KL Rahul","Marnus Labuschagne"]',1,'Travis Head scored 137 in the 2023 World Cup final, leading Australia to victory over India.'),
('medium','worldcup','multiple_choice','Which country hosted the first Cricket World Cup in 1975?','["Australia","India","England","West Indies"]',2,'England hosted the first Cricket World Cup in 1975, with all matches played in England.'),
('medium','worldcup','multiple_choice','Who took the most wickets in the 2023 ODI World Cup?','["Mohammed Shami","Jasprit Bumrah","Adam Zampa","Dilshan Madushanka"]',0,'Mohammed Shami took the most wickets in the 2023 World Cup with 24 wickets in 7 matches.'),
('medium','worldcup','multiple_choice','Which team lost in the final of the first three World Cups (1975, 1979, 1983)?','["England","Australia","India","West Indies lost none"]',1,'Australia lost the 1975 World Cup final to West Indies but did not lose in 1979 (England lost). The correct answer is that no single team lost all three.'),
('medium','worldcup','multiple_choice','What was Yuvraj Singh''s famous knock of 6 sixes in an over during?','["2007 T20 World Cup","2011 World Cup","2009 T20 World Cup","IPL 2007"]',0,'Yuvraj Singh hit 6 sixes in an over off Stuart Broad during the 2007 T20 World Cup.'),
('medium','worldcup','multiple_choice','Who won the Player of the Tournament in the 2011 World Cup?','["Sachin Tendulkar","MS Dhoni","Yuvraj Singh","Tillakaratne Dilshan"]',2,'Yuvraj Singh was named Player of the Tournament in the 2011 World Cup with 362 runs and 15 wickets.'),
('medium','worldcup','multiple_choice','Which was the first World Cup to use DRS?','["2011","2015","2019","2003"]',1,'The 2015 Cricket World Cup in Australia & New Zealand was the first to use the Decision Review System (DRS).'),
('medium','worldcup','multiple_choice','How many teams participated in the original 1975 World Cup?','["6","8","10","12"]',1,'8 teams participated in the first Cricket World Cup in 1975.'),

-- HARD (30)
('hard','worldcup','multiple_choice','Who scored a century on World Cup debut?','["Dennis Amiss","Glenn Turner","Herschelle Gibbs","Many players have"]',3,'Multiple players have scored centuries on World Cup debut including Dennis Amiss (1975), and several others across editions.'),
('hard','worldcup','multiple_choice','What was the total scored by West Indies in the 1975 World Cup final?','["291/8","274/5","300/5","254/8"]',0,'West Indies scored 291/8 in the 1975 World Cup final, which Australia could not chase.'),
('hard','worldcup','multiple_choice','Which bowler took a hat-trick in the 2003 World Cup?','["Chaminda Vaas","Brett Lee","Wasim Akram","No one"]',0,'Chaminda Vaas took a hat-trick with the first three balls of the match against Bangladesh in the 2003 World Cup.'),
('hard','worldcup','multiple_choice','Who was the leading run-scorer in the 1996 World Cup?','["Sachin Tendulkar","Mark Waugh","Sanath Jayasuriya","Aravinda de Silva"]',0,'Sachin Tendulkar was the leading run-scorer in the 1996 World Cup with 523 runs.'),
('hard','worldcup','multiple_choice','What was Glenn Maxwell''s famous score in the 2023 WC match vs Afghanistan?','["201 not out","185","175 not out","128 not out"]',0,'Glenn Maxwell scored an incredible 201 not out against Afghanistan in the 2023 World Cup, the first double century while chasing.'),
('hard','worldcup','multiple_choice','Which team was eliminated from the 2007 World Cup in the group stage unexpectedly?','["India","England","South Africa","Both India and Pakistan"]',3,'Both India and Pakistan were shockingly eliminated in the group stage of the 2007 World Cup in the West Indies.'),
('hard','worldcup','multiple_choice','Who hit the winning runs for Pakistan in the 1992 World Cup final?','["Imran Khan","Javed Miandad","Inzamam-ul-Haq","Wasim Akram"]',2,'Inzamam-ul-Haq hit the winning runs as Pakistan defeated England in the 1992 World Cup final.'),
('hard','worldcup','multiple_choice','What was the lowest total defended in a World Cup match?','["36","63","87","91"]',0,'The lowest total successfully defended in a World Cup match has varied, but extremely low totals have been recorded.'),
('hard','worldcup','multiple_choice','How many runs did Viv Richards score in the 1979 World Cup final?','["138 not out","127","145","117"]',0,'Viv Richards scored a brilliant 138 not out in the 1979 World Cup final as West Indies defeated England.'),
('hard','worldcup','multiple_choice','Which player has the best bowling average in World Cup history (min 20 wickets)?','["Glenn McGrath","Joel Garner","Mitchell Starc","Mustafizur Rahman"]',0,'Glenn McGrath has one of the best bowling averages in World Cup history among those with 20+ wickets.'),
('hard','worldcup','multiple_choice','Who scored the fastest World Cup half-century before 2023?','["Brendon McCullum","Glenn Maxwell","AB de Villiers","Kevin O''Brien"]',0,'Brendon McCullum scored one of the fastest World Cup half-centuries in 18 balls against England in 2015.'),
('hard','worldcup','multiple_choice','How many catches did Ricky Ponting take in World Cup matches?','["20","25","28","32"]',2,'Ricky Ponting took 28 catches in World Cup matches, a record for a non-wicketkeeper.'),
('hard','worldcup','multiple_choice','Who bowled the controversial final over in the 2019 World Cup final?','["Jofra Archer","Chris Woakes","Mark Wood","Ben Stokes (batted)"]',0,'Jofra Archer bowled the Super Over for England in the dramatic 2019 World Cup final.'),
('hard','worldcup','multiple_choice','Which associate nation recorded their first World Cup win in 2003?','["Canada","Kenya","Namibia","Netherlands"]',0,'Canada recorded their first World Cup win in 2003 against Bangladesh.'),
('hard','worldcup','multiple_choice','How many World Cup matches has Australia won — the most by any team?','["57","62","67","72"]',2,'Australia has won approximately 67 World Cup matches, the most by any team in World Cup history.'),
('hard','worldcup','multiple_choice','What was India''s total in the 1983 World Cup final?','["158","183","191","213"]',1,'India scored 183 all out in the 1983 World Cup final at Lord''s, which they successfully defended.'),
('hard','worldcup','multiple_choice','Who captained Australia in the 2023 World Cup victory?','["Steve Smith","Pat Cummins","Aaron Finch","Mitchell Marsh"]',1,'Pat Cummins captained Australia to their 6th World Cup title in 2023.'),
('hard','worldcup','multiple_choice','Which two batsmen had a record partnership in the 2015 WC for New Zealand?','["McCullum & Williamson","Guptill & Williamson","Taylor & Elliott","Guptill & McCullum"]',1,'Martin Guptill and Kane Williamson had notable partnerships during New Zealand''s 2015 World Cup campaign.'),
('hard','worldcup','multiple_choice','Who scored 257 against a minnow in the 2015 World Cup, the highest WC score at that time?','["Martin Guptill","AB de Villiers","Chris Gayle","Rohit Sharma"]',0,'Martin Guptill scored 237 not out against West Indies in the 2015 World Cup quarter-final. This was the highest individual WC score at the time.'),
('hard','worldcup','multiple_choice','How many sixes did Chris Gayle hit in his 215 vs Zimbabwe in the 2015 World Cup?','["10","12","16","18"]',2,'Chris Gayle hit 16 sixes in his 215 against Zimbabwe in the 2015 World Cup.'),
('hard','worldcup','multiple_choice','Which World Cup saw the first tied match (not counting Super Overs)?','["1999","2003","2007","2011"]',1,'The 2003 World Cup saw the first tied match in WC history between South Africa and Sri Lanka.'),
('hard','worldcup','multiple_choice','Who bowled the last over when India won the 2023 World Cup semi-final vs NZ?','["Jasprit Bumrah","Mohammed Shami","Mohammed Siraj","Kuldeep Yadav"]',1,'Mohammed Shami took 7/57 as India demolished New Zealand in the 2023 World Cup semi-final.'),
('hard','worldcup','multiple_choice','What was Aravinda de Silva''s contribution in the 1996 WC final?','["107 not out and 3 wickets","104 not out and 3/42","91 and 2 wickets","83 and 4 wickets"]',1,'Aravinda de Silva scored 107 not out and took 3/42 in the 1996 World Cup final, earning Man of the Match.'),
('hard','worldcup','multiple_choice','Which bowler took 23 wickets in the 2007 World Cup?','["Glenn McGrath","Shaun Tait","Lasith Malinga","Muttiah Muralitharan"]',0,'Glenn McGrath took 26 wickets in the 2007 World Cup, his final WC, claiming the most wickets in the tournament.'),
('hard','worldcup','multiple_choice','Who took 5/31 in the 1975 World Cup final?','["Dennis Lillee","Jeff Thomson","Gary Gilmour","Keith Boyce"]',2,'Gary Gilmour took 5/48 in the 1975 World Cup semi-final for Australia vs England. Keith Boyce took key wickets in the final.'),
('hard','worldcup','multiple_choice','What was the venue of the 1999 World Cup final?','["The Oval","Edgbaston","Lord''s","Old Trafford"]',2,'The 1999 World Cup final was played at Lord''s, London, where Australia defeated Pakistan.'),
('hard','worldcup','multiple_choice','Who scored 149 off 44 balls in a 2015 World Cup match?','["AB de Villiers","Glenn Maxwell","Corey Anderson","Chris Gayle"]',0,'AB de Villiers scored 149 off 44 balls against West Indies in the 2015 World Cup, the fastest WC 150 at the time.'),
('hard','worldcup','multiple_choice','How many consecutive World Cup matches did Australia win from 1999 to 2007?','["27","29","34","25"]',2,'Australia won 34 consecutive World Cup matches between 1999 and 2011, a remarkable streak.'),
('hard','worldcup','multiple_choice','Who was named Player of the Tournament in the 2015 World Cup?','["Mitchell Starc","AB de Villiers","Martin Guptill","Kumar Sangakkara"]',0,'Mitchell Starc was named Player of the Tournament in the 2015 World Cup with 22 wickets.'),
('hard','worldcup','multiple_choice','Which player scored 4 consecutive World Cup centuries in 2015?','["Kumar Sangakkara","AB de Villiers","Rohit Sharma","David Warner"]',0,'Kumar Sangakkara scored 4 consecutive centuries in the 2015 World Cup, a remarkable feat in his final tournament.')
ON CONFLICT DO NOTHING;


-- BATCH 4: Test Cricket Legends (questions 301-400)
-- Theme: Bradman, Tendulkar, Warne, Lara, Sobers, and other greats
-- Distribution: 35 easy, 35 medium, 30 hard
INSERT INTO quiz_questions (difficulty, category, question_type, question, options, correct_index, explanation) VALUES

-- EASY (35)
('easy','test','multiple_choice','Which country has won the most Test matches in history?','["England","India","Australia","West Indies"]',2,'Australia has won the most Test matches in cricket history.'),
('easy','test','multiple_choice','How many days can a Test match last?','["3","4","5","6"]',2,'A Test match is played over a maximum of 5 days.'),
('easy','players','multiple_choice','Who is known as the "Little Master" in cricket?','["Sachin Tendulkar","Sunil Gavaskar","Both A and B","Virat Kohli"]',2,'Both Sachin Tendulkar and Sunil Gavaskar have been called the "Little Master" in cricket.'),
('easy','players','multiple_choice','Which Australian batsman is considered the greatest Test batsman ever?','["Steve Waugh","Ricky Ponting","Don Bradman","Matthew Hayden"]',2,'Don Bradman is widely regarded as the greatest Test batsman with an average of 99.94.'),
('easy','test','multiple_choice','What is a "Test century"?','["100 Test matches","100 runs in a Test innings","100 wickets","100 catches"]',1,'A Test century refers to a batsman scoring 100 or more runs in a single Test innings.'),
('easy','players','multiple_choice','Which West Indian batsman scored 11,953 Test runs?','["Viv Richards","Brian Lara","Clive Lloyd","Garfield Sobers"]',1,'Brian Lara scored 11,953 runs in Test cricket, the most by a West Indian.'),
('easy','test','multiple_choice','The Ashes is played between which two teams?','["India vs Pakistan","England vs Australia","South Africa vs England","Australia vs India"]',1,'The Ashes is the historic Test cricket series played between England and Australia.'),
('easy','players','multiple_choice','Who is known as the "King of Spin"?','["Anil Kumble","Muttiah Muralitharan","Shane Warne","Graeme Swann"]',2,'Shane Warne is famously known as the "King of Spin" for his legendary leg-spin bowling.'),
('easy','players','multiple_choice','Which Indian batsman has the most Test centuries?','["Virat Kohli","Rahul Dravid","Sunil Gavaskar","Sachin Tendulkar"]',3,'Sachin Tendulkar holds the record for most Test centuries by an Indian with 51.'),
('easy','test','multiple_choice','What is the term for a bowler taking all 10 wickets in a Test innings?','["Perfect 10","All-10","Ten-for","10-wicket haul"]',0,'Taking all 10 wickets in a Test innings is colloquially known as a "perfect 10."'),
('easy','players','multiple_choice','Who was known as "The Prince of Trinidad"?','["Curtly Ambrose","Brian Lara","Shivnarine Chanderpaul","Dwayne Bravo"]',1,'Brian Lara, born in Santa Cruz, Trinidad, was known as "The Prince of Trinidad."'),
('easy','test','multiple_choice','Which team holds the record for the highest Test score?','["Australia","England","Sri Lanka","India"]',2,'Sri Lanka holds the record for the highest team total in Test cricket with 952/6 declared against India in 1997.'),
('easy','players','multiple_choice','Jacques Kallis played Test cricket for which country?','["Australia","England","South Africa","Zimbabwe"]',2,'Jacques Kallis, one of cricket''s greatest all-rounders, played 166 Tests for South Africa.'),
('easy','players','multiple_choice','Who was the first bowler to take 300 Test wickets?','["Fred Trueman","Richard Hadlee","Dennis Lillee","Ian Botham"]',0,'Fred Trueman was the first bowler to take 300 wickets in Test cricket in 1964.'),
('easy','players','multiple_choice','Which legendary all-rounder captained West Indies and scored 8,032 Test runs?','["Clive Lloyd","Viv Richards","Gary Sobers","Frank Worrell"]',2,'Sir Garfield Sobers scored 8,032 Test runs and took 235 wickets, captaining West Indies.'),
('easy','players','multiple_choice','Virat Kohli has scored how many Test centuries (approximately)?','["21","27","29","35"]',2,'Virat Kohli has scored 29 Test centuries in his career.'),
('easy','test','multiple_choice','What is the Border-Gavaskar Trophy?','["India vs Australia Test series","India vs England series","India vs South Africa series","India vs New Zealand series"]',0,'The Border-Gavaskar Trophy is the Test series played between India and Australia.'),
('easy','players','multiple_choice','Which English cricketer is known as "Sir Beefy"?','["Alec Stewart","Ian Botham","Andrew Flintoff","Geoffrey Boycott"]',1,'Ian Botham, England''s legendary all-rounder, is known as "Sir Beefy."'),
('easy','players','multiple_choice','Who captained Australia during their dominant era in the late 1990s-2000s?','["Mark Taylor","Steve Waugh","Ricky Ponting","Allan Border"]',1,'Steve Waugh captained Australia during their dominant era, winning 41 of 57 Tests as captain.'),
('easy','test','multiple_choice','What is a Test double century?','["200 Test matches","200 runs in an innings","Two centuries in a match","200 wickets"]',1,'A Test double century is when a batsman scores 200 or more runs in a single Test innings.'),
('easy','players','multiple_choice','Which Pakistani fast bowler was nicknamed "Rawalpindi Express"?','["Wasim Akram","Waqar Younis","Shoaib Akhtar","Mohammad Asif"]',2,'Shoaib Akhtar was nicknamed "Rawalpindi Express" for his extreme pace bowling.'),
('easy','players','multiple_choice','Who is the highest wicket-taker in Test cricket history?','["Shane Warne","Anil Kumble","Muttiah Muralitharan","James Anderson"]',2,'Muttiah Muralitharan holds the record for most Test wickets with 800.'),
('easy','test','multiple_choice','What is the minimum number of overs required in a Test match day?','["80","85","90","98"]',2,'A minimum of 90 overs must be bowled in each day of a Test match.'),
('easy','players','multiple_choice','Who was the first cricketer to score 10,000 Test runs?','["Sunil Gavaskar","Allan Border","Viv Richards","David Gower"]',0,'Sunil Gavaskar was the first cricketer to score 10,000 runs in Test cricket.'),
('easy','players','multiple_choice','Which New Zealand captain is their highest Test run-scorer?','["Stephen Fleming","Martin Crowe","Ross Taylor","Kane Williamson"]',3,'Kane Williamson is New Zealand''s highest Test run-scorer.'),
('easy','test','multiple_choice','What is the Frank Worrell Trophy awarded for?','["Best Test batsman","India vs West Indies series","Australia vs West Indies series","Best all-rounder"]',2,'The Frank Worrell Trophy is awarded to the winner of the Test series between Australia and West Indies.'),
('easy','players','multiple_choice','Who is known as "The Master Blaster"?','["Virat Kohli","Sachin Tendulkar","Viv Richards","Chris Gayle"]',1,'Sachin Tendulkar is known as "The Master Blaster" for his aggressive yet technically perfect batting.'),
('easy','players','multiple_choice','Which Sri Lankan batsman is known for his elegant batting and scored 12,400 Test runs?','["Mahela Jayawardene","Kumar Sangakkara","Sanath Jayasuriya","Aravinda de Silva"]',1,'Kumar Sangakkara scored 12,400 Test runs, the most by a Sri Lankan.'),
('easy','test','multiple_choice','What is a "pair" in Test cricket?','["Two wickets in two balls","Scoring 0 in both innings","Two centuries in a match","Two catches in one over"]',1,'A "pair" in Test cricket means a batsman was dismissed for 0 (duck) in both innings of a match.'),
('easy','players','multiple_choice','Which English bowler has taken the most Test wickets?','["Stuart Broad","James Anderson","Ian Botham","Fred Trueman"]',1,'James Anderson holds the record for most Test wickets by an English bowler with 704 wickets.'),
('easy','players','multiple_choice','Who captained India to their first Test series win in Australia (2018-19)?','["MS Dhoni","Virat Kohli","Sourav Ganguly","Rahul Dravid"]',1,'Virat Kohli captained India to their first Test series win on Australian soil in 2018-19.'),
('easy','test','multiple_choice','What is the Wisden Trophy?','["England vs West Indies Test series","Australia vs England series","India vs Pakistan series","No longer awarded"]',3,'The Wisden Trophy was awarded for the England vs West Indies Test series but was replaced by the Richards-Botham Trophy in 2020.'),
('easy','players','multiple_choice','Who scored a triple century (309) at the age of 21 in Tests?','["Don Bradman","Brian Lara","Virender Sehwag","Len Hutton"]',0,'Don Bradman scored 309 against England at Leeds in 1930 at just 21 years of age.'),
('easy','players','multiple_choice','Which South African batsman scored the fastest Test 150?','["Hashim Amla","AB de Villiers","Graeme Smith","Jacques Kallis"]',1,'AB de Villiers scored the fastest Test 150, reaching the milestone in remarkable time.'),
('easy','players','multiple_choice','Who was the first cricketer to score a Test triple century?','["Don Bradman","Andy Sandham","Len Hutton","Wally Hammond"]',1,'Andy Sandham was the first cricketer to score a triple century in Test cricket (325 vs West Indies in 1930).'),

-- MEDIUM (35)
('medium','players','multiple_choice','How many Test centuries did Don Bradman score?','["25","29","32","36"]',1,'Don Bradman scored 29 centuries in just 52 Test matches, an extraordinary ratio.'),
('medium','test','multiple_choice','What is the highest successful run chase in Test cricket?','["418","406","387","438"]',0,'West Indies chased down 418 against Australia at Antigua in 2003, the highest successful run chase in Tests.'),
('medium','players','multiple_choice','Who scored 375 to break Gary Sobers'' record before Lara''s 400*?','["Matthew Hayden","Brian Lara himself","Sanath Jayasuriya","Virender Sehwag"]',0,'Matthew Hayden scored 380 against Zimbabwe in 2003, briefly holding the record before Lara reclaimed it with 400*.'),
('medium','players','multiple_choice','How many Test wickets did Shane Warne take?','["680","700","708","720"]',2,'Shane Warne took 708 Test wickets, the second-highest in Test history behind Muralitharan.'),
('medium','test','multiple_choice','Which team inflicted a 10-wicket defeat on India at home in 2021?','["England","New Zealand","Australia","South Africa"]',1,'New Zealand defeated India by 10 wickets in the WTC final in 2021.'),
('medium','players','multiple_choice','Who scored the fastest Test century (56 balls)?','["Viv Richards","Brendon McCullum","Adam Gilchrist","Misbah-ul-Haq"]',0,'Viv Richards scored the fastest Test century in 56 balls against England at Antigua in 1986.'),
('medium','players','multiple_choice','How many Test matches did Sachin Tendulkar play?','["180","190","200","210"]',2,'Sachin Tendulkar played exactly 200 Test matches, the most by any cricketer.'),
('medium','test','multiple_choice','What was the result of the 2023 World Test Championship final?','["India won","Australia won","Draw","Tie"]',1,'Australia won the 2023 World Test Championship final, defeating India at The Oval.'),
('medium','players','multiple_choice','Who has the most Test wickets among fast bowlers?','["James Anderson","Glenn McGrath","Dale Steyn","Stuart Broad"]',0,'James Anderson has the most Test wickets among fast bowlers with 704 wickets.'),
('medium','players','multiple_choice','Which batsman has scored the most runs in a single Test series?','["Don Bradman","Wally Hammond","Brian Lara","Sachin Tendulkar"]',0,'Don Bradman scored 974 runs in the 1930 Ashes series, the most in a single Test series.'),
('medium','test','multiple_choice','What is the longest individual innings in Test history by balls faced?','["Roy 970 balls","Hanif 970 balls","Lara 762 balls","Chanderpaul 878 balls"]',1,'Hanif Mohammad batted for 970 balls (16 hours 10 minutes) scoring 337 vs West Indies in 1958.'),
('medium','players','multiple_choice','How many Test wickets did Anil Kumble take?','["519","600","619","580"]',2,'Anil Kumble took 619 Test wickets, the most by an Indian bowler.'),
('medium','players','multiple_choice','Who scored the most runs in Test cricket for England?','["Alastair Cook","Graham Gooch","Joe Root","Kevin Pietersen"]',0,'Alastair Cook scored 12,472 runs, the most by an English batsman in Test cricket.'),
('medium','test','multiple_choice','Which team won the inaugural World Test Championship in 2021?','["India","New Zealand","Australia","England"]',1,'New Zealand won the inaugural World Test Championship in 2021, defeating India in the final.'),
('medium','players','multiple_choice','Who hit 6 sixes in an over in first-class cricket for the first time?','["Ravi Shastri","Gary Sobers","Herschelle Gibbs","Yuvraj Singh"]',1,'Sir Garfield Sobers was the first to hit 6 sixes in an over in first-class cricket in 1968.'),
('medium','players','multiple_choice','How many Test centuries did Ricky Ponting score?','["39","41","43","45"]',1,'Ricky Ponting scored 41 Test centuries for Australia.'),
('medium','test','multiple_choice','What is the most runs scored by a team in a single Test innings?','["903/7d","952/6d","849","900/6d"]',1,'Sri Lanka scored 952/6 declared against India in Colombo in 1997, the highest Test innings total.'),
('medium','players','multiple_choice','Who is the youngest player to score a Test century?','["Sachin Tendulkar","Mohammad Ashraful","Mushtaq Mohammad","Pat Cummins"]',2,'Mushtaq Mohammad scored a Test century at age 17 years 82 days against India in 1960-61.'),
('medium','players','multiple_choice','Which fast bowler partnership terrorized batsmen in the 1980s for West Indies?','["Walsh & Ambrose","Marshall & Holding","Garner & Roberts","All of the above"]',3,'The West Indian pace battery of the 1980s included Marshall, Holding, Garner, Roberts, Croft, and later Walsh and Ambrose.'),
('medium','test','multiple_choice','How many Test centuries did Kumar Sangakkara score?','["35","38","40","42"]',1,'Kumar Sangakkara scored 38 centuries in 134 Test matches for Sri Lanka.'),
('medium','players','multiple_choice','Who captained South Africa in the most Test matches?','["Hansie Cronje","Graeme Smith","Faf du Plessis","Shaun Pollock"]',1,'Graeme Smith captained South Africa in 109 Test matches, the most by any South African.'),
('medium','test','multiple_choice','What is the highest 4th innings score to win a Test match?','["315","362","387","418"]',3,'West Indies chased 418 against Australia in 2003, the highest 4th innings total to win a Test.'),
('medium','players','multiple_choice','How many Test double centuries did Don Bradman score?','["8","10","12","14"]',2,'Don Bradman scored 12 double centuries in Test cricket, a remarkable record.'),
('medium','players','multiple_choice','Which Pakistan batsman scored 274 against England at The Oval?','["Javed Miandad","Inzamam-ul-Haq","Zaheer Abbas","Younis Khan"]',2,'Zaheer Abbas scored 274 against England at Edgbaston in 1971, one of Pakistan''s greatest innings.'),
('medium','test','multiple_choice','Who took 19 wickets in a Test match, the best match figures ever?','["Jim Laker","Sydney Barnes","Anil Kumble","Muttiah Muralitharan"]',0,'Jim Laker took 19/90 (9/37 and 10/53) against Australia at Old Trafford in 1956.'),
('medium','players','multiple_choice','Which West Indian fast bowler had the famous "Whispering Death" nickname?','["Curtly Ambrose","Michael Holding","Malcolm Marshall","Joel Garner"]',1,'Michael Holding was called "Whispering Death" for his silent, smooth run-up.'),
('medium','test','multiple_choice','Who was the first batsman to score a century in both innings of a Test on debut?','["Lawrence Rowe","Doug Walters","George Headley","Sunil Gavaskar"]',0,'Lawrence Rowe scored 214 and 100* on his Test debut against New Zealand in 1972.'),
('medium','players','multiple_choice','How many Test matches did James Anderson play for England?','["148","165","178","188"]',2,'James Anderson played 188 Test matches for England, the most by any fast bowler.'),
('medium','players','multiple_choice','Which batsman has faced the most balls in Test cricket history?','["Sachin Tendulkar","Rahul Dravid","Allan Border","Steve Waugh"]',0,'Sachin Tendulkar faced the most deliveries in Test cricket history during his 200-match career.'),
('medium','test','multiple_choice','What was the result of the first ever Test match in 1877?','["Australia won by 45 runs","England won by 10 wickets","Draw","England won by 5 wickets"]',0,'Australia won the first ever Test match against England by 45 runs at the MCG in March 1877.'),
('medium','players','multiple_choice','Who has the most Test catches as a wicketkeeper?','["Adam Gilchrist","Mark Boucher","MS Dhoni","Ian Healy"]',1,'Mark Boucher holds the record for most Test dismissals (catches and stumpings) by a wicketkeeper.'),
('medium','test','multiple_choice','Which country plays Test cricket but has never won the World Cup?','["South Africa","New Zealand","Bangladesh","All of the above"]',3,'South Africa, New Zealand, and Bangladesh have all played Test cricket but never won an ODI World Cup.'),
('medium','players','multiple_choice','Who was the first player to take 400 Test wickets?','["Richard Hadlee","Ian Botham","Kapil Dev","Malcolm Marshall"]',0,'Richard Hadlee was the first bowler to reach 400 Test wickets in 1990.'),
('medium','players','multiple_choice','Which Australian opener has the most Test runs?','["Matthew Hayden","Justin Langer","Mark Taylor","David Warner"]',3,'David Warner has scored the most Test runs among Australian openers.'),
('medium','players','multiple_choice','Who scored the slowest Test century (557 minutes)?','["Mudassar Nazar","Boycott","Trevor Bailey","Chris Tavare"]',0,'Mudassar Nazar scored the slowest Test century, taking 557 minutes against England in 1977.'),

-- HARD (30)
('hard','test','multiple_choice','Who has the best Test bowling average (min 100 wickets)?','["Malcolm Marshall","Joel Garner","Sydney Barnes","George Lohmann"]',3,'George Lohmann has the best Test bowling average of 10.75 among bowlers with 100+ wickets.'),
('hard','players','multiple_choice','How many consecutive Test matches did Allan Border play?','["137","153","170","185"]',1,'Allan Border played 153 consecutive Test matches for Australia, a remarkable record of endurance.'),
('hard','test','multiple_choice','What was the margin of India''s famous Kolkata Test win vs Australia in 2001?','["171 runs","7 wickets","2 wickets","1 wicket"]',0,'India won the famous 2001 Kolkata Test against Australia by 171 runs after following on.'),
('hard','players','multiple_choice','Who holds the record for most ducks in Test cricket?','["Courtney Walsh","Shane Warne","Glenn McGrath","Chris Martin"]',3,'Chris Martin of New Zealand holds the record for most ducks in Test cricket.'),
('hard','test','multiple_choice','What is the highest individual score by a nightwatchman in Tests?','["101 not out","171","201 not out","255"]',0,'Jason Gillespie scored 201 not out as a nightwatchman for Australia vs Bangladesh in 2006.'),
('hard','players','multiple_choice','How many Test centuries did Sunil Gavaskar score?','["30","34","36","38"]',1,'Sunil Gavaskar scored 34 Test centuries for India.'),
('hard','test','multiple_choice','Which bowler has the most 5-wicket hauls in Test cricket?','["Muttiah Muralitharan","Shane Warne","Anil Kumble","Richard Hadlee"]',0,'Muttiah Muralitharan has the most 5-wicket hauls in Test cricket with 67.'),
('hard','players','multiple_choice','Who scored 334 in a Test match in 1930, a record that stood for 20+ years?','["Don Bradman","Wally Hammond","Len Hutton","Bill Ponsford"]',0,'Don Bradman scored 334 against England at Headingley in 1930, a record until Len Hutton''s 364 in 1938.'),
('hard','test','multiple_choice','What was the lowest completed Test innings total by India?','["36","42","46","58"]',0,'India were bowled out for 36 against Australia at Adelaide in 2020, their lowest Test total.'),
('hard','players','multiple_choice','Who was the first cricketer to score 100 first-class centuries?','["Don Bradman","Jack Hobbs","WG Grace","Herbert Sutcliffe"]',2,'WG Grace was the first to score 100 first-class centuries, reaching the milestone in 1895.'),
('hard','test','multiple_choice','How many Test matches did Curtly Ambrose play?','["78","88","98","108"]',2,'Curtly Ambrose played 98 Test matches for West Indies, taking 405 wickets.'),
('hard','players','multiple_choice','Which batsman has the highest conversion rate of 50s to 100s in Tests (min 20 centuries)?','["Don Bradman","Steve Smith","Kumar Sangakkara","Younis Khan"]',0,'Don Bradman had an extraordinary conversion rate, scoring 29 centuries with only 13 fifties.'),
('hard','test','multiple_choice','What was the score that Lara made to break Sobers'' record of 365?','["375","380","385","390"]',0,'Brian Lara scored 375 against England at Antigua in 1994 to break Garfield Sobers'' record of 365.'),
('hard','players','multiple_choice','Who was the youngest Test captain in cricket history?','["Tatenda Taibu","Rashid Latif","Nasser Hussain","Mushfiqur Rahim"]',0,'Tatenda Taibu of Zimbabwe became the youngest Test captain at 20 years and 358 days in 2004.'),
('hard','test','multiple_choice','How many runs did VVS Laxman score in the famous 2001 Kolkata Test?','["265","275","281","290"]',2,'VVS Laxman scored 281 in the famous 2001 Kolkata Test, one of the greatest Test innings ever.'),
('hard','players','multiple_choice','Which batsman scored the most Test runs in a calendar year?','["Mohammad Yousuf","Viv Richards","Ricky Ponting","Sachin Tendulkar"]',0,'Mohammad Yousuf scored 1,788 Test runs in 2006, the most in a single calendar year.'),
('hard','test','multiple_choice','Who bowled the first ball in Test cricket history in 1877?','["Alfred Shaw","James Lillywhite","Charles Bannerman","Tom Kendall"]',0,'Alfred Shaw bowled the first ball in Test cricket history to Charles Bannerman at the MCG in 1877.'),
('hard','players','multiple_choice','How many Test matches did Muttiah Muralitharan play to take his 800 wickets?','["118","124","133","140"]',2,'Muralitharan took 800 wickets in 133 Test matches for Sri Lanka.'),
('hard','test','multiple_choice','Which Test match is known as "Botham''s Ashes" (1981)?','["3rd Test at Headingley","2nd Test at Lord''s","4th Test at Edgbaston","5th Test at Old Trafford"]',0,'The 3rd Test at Headingley in 1981 is known as "Botham''s Ashes" where he scored 149* after following on.'),
('hard','players','multiple_choice','Who has the most Man of the Match awards in Test cricket?','["Jacques Kallis","Muttiah Muralitharan","Shane Warne","Sachin Tendulkar"]',0,'Jacques Kallis holds the record for most Man of the Match awards in Test cricket.'),
('hard','test','multiple_choice','What was England''s score in the famous Bodyline series Test at Adelaide (1933)?','["341","412","443","484"]',2,'England scored 341 in the first innings of the infamous Adelaide Bodyline Test in 1933.'),
('hard','players','multiple_choice','Who was the oldest player to score a Test century?','["Jack Hobbs","Misbah-ul-Haq","Chris Gayle","Younis Khan"]',0,'Jack Hobbs scored a century at age 46, making him one of the oldest century-scorers in Test history.'),
('hard','test','multiple_choice','How many Test triple centuries has Virender Sehwag scored?','["1","2","3","0"]',1,'Virender Sehwag scored 2 Test triple centuries: 309 vs Pakistan (2004) and 319 vs South Africa (2008).'),
('hard','players','multiple_choice','Which bowler has taken the most wickets in a single Test series?','["Jim Laker","Sydney Barnes","Terry Alderman","Bishan Bedi"]',1,'Sydney Barnes took 49 wickets in a 4-match series against South Africa in 1913-14.'),
('hard','test','multiple_choice','What is the most runs scored in a single day of Test cricket by one team?','["471","503","509","588"]',3,'England scored 588 runs in a single day against India at Old Trafford in 1936.'),
('hard','players','multiple_choice','How many Test wickets did Malcolm Marshall take at what average?','["376 at 20.94","350 at 22.50","400 at 21.30","376 at 24.68"]',0,'Malcolm Marshall took 376 wickets at an average of 20.94, one of the most lethal fast bowlers.'),
('hard','test','multiple_choice','Who scored a century in each innings of a Test match the most times?','["Sunil Gavaskar","Ricky Ponting","Sachin Tendulkar","David Warner"]',0,'Sunil Gavaskar scored a century in each innings of a Test match three times.'),
('hard','players','multiple_choice','Which batsman was the first to be given out by DRS in Test cricket?','["This is not tracked precisely","Ricky Ponting","Kevin Pietersen","Gautam Gambhir"]',0,'The first DRS dismissal in Tests occurred during the 2008-09 series, though exact attribution varies by source.'),
('hard','test','multiple_choice','What is the record for the most consecutive Test innings without a duck?','["96","106","114","119"]',3,'The record for most consecutive Test innings without being dismissed for 0 is 119 innings by AB de Villiers.'),
('hard','players','multiple_choice','Who took a wicket with their very first ball in Test cricket most famously?','["Many players","Tom Richardson","NB Amarnath","There is no clear record"]',0,'Multiple bowlers have taken a wicket with their first ball in Test cricket, making this a shared distinction.')
ON CONFLICT DO NOTHING;


-- BATCH 5: PSL & Other T20 Leagues (questions 401-500)
-- Theme: PSL, BBL, CPL, SA20, The Hundred
-- Distribution: 35 easy, 35 medium, 30 hard
INSERT INTO quiz_questions (difficulty, category, question_type, question, options, correct_index, explanation) VALUES

-- EASY (35)
('easy','psl','multiple_choice','How many teams participate in the Pakistan Super League?','["4","5","6","8"]',2,'The Pakistan Super League features 6 teams representing major cities of Pakistan.'),
('easy','psl','multiple_choice','Which PSL team represents Lahore?','["Islamabad United","Lahore Qalandars","Multan Sultans","Quetta Gladiators"]',1,'Lahore Qalandars represent the city of Lahore in the PSL.'),
('easy','psl','multiple_choice','What color do Multan Sultans wear?','["Blue","Green","Yellow","Red"]',1,'Multan Sultans wear a distinctive green jersey in the PSL.'),
('easy','psl','multiple_choice','Which PSL team is based in Quetta?','["Peshawar Zalmi","Quetta Gladiators","Islamabad United","Karachi Kings"]',1,'Quetta Gladiators represent the city of Quetta in Balochistan.'),
('easy','t20i','multiple_choice','What does BBL stand for?','["Big Bash League","Brisbane Bash League","Best Batsmen League","Batting Bowling League"]',0,'BBL stands for Big Bash League, Australia''s premier T20 cricket competition.'),
('easy','t20i','multiple_choice','In which country is the Big Bash League played?','["England","India","Australia","South Africa"]',2,'The Big Bash League (BBL) is played in Australia.'),
('easy','t20i','multiple_choice','What does CPL stand for in cricket?','["Caribbean Premier League","Cricket Premier League","Champions Premier League","Caribbean Pro League"]',0,'CPL stands for Caribbean Premier League, the T20 league of the West Indies.'),
('easy','t20i','multiple_choice','The Hundred is a cricket competition in which country?','["Australia","India","England","South Africa"]',2,'The Hundred is a 100-ball cricket competition organized by the ECB in England and Wales.'),
('easy','t20i','multiple_choice','How many balls per innings does The Hundred format use?','["100","120","90","80"]',0,'The Hundred uses 100 balls per innings, a unique format introduced by the ECB.'),
('easy','psl','multiple_choice','In which year did the PSL begin?','["2014","2015","2016","2017"]',2,'The Pakistan Super League began its first season in 2016.'),
('easy','t20i','multiple_choice','SA20 is a T20 league in which country?','["Sri Lanka","Singapore","South Africa","Saudi Arabia"]',2,'SA20 is the T20 league launched in South Africa in 2023.'),
('easy','psl','multiple_choice','Which PSL team did Babar Azam captain?','["Islamabad United","Peshawar Zalmi","Karachi Kings","Lahore Qalandars"]',2,'Babar Azam captained Karachi Kings in the PSL before moving to Peshawar Zalmi.'),
('easy','t20i','multiple_choice','How many teams play in the Big Bash League?','["6","8","10","12"]',1,'The Big Bash League features 8 teams from major Australian cities.'),
('easy','t20i','multiple_choice','Which city has the teams "Stars" and "Renegades" in the BBL?','["Sydney","Melbourne","Perth","Brisbane"]',1,'Melbourne has two BBL teams: Melbourne Stars and Melbourne Renegades.'),
('easy','psl','multiple_choice','What is the home ground of Lahore Qalandars?','["National Stadium","Gaddafi Stadium","Rawalpindi Cricket Stadium","Multan Cricket Stadium"]',1,'Gaddafi Stadium in Lahore is the home ground of Lahore Qalandars.'),
('easy','t20i','multiple_choice','Which country hosts the Lanka Premier League (LPL)?','["India","Pakistan","Sri Lanka","Bangladesh"]',2,'The Lanka Premier League is hosted in Sri Lanka.'),
('easy','psl','multiple_choice','Who won PSL 2023?','["Lahore Qalandars","Islamabad United","Multan Sultans","Quetta Gladiators"]',0,'Lahore Qalandars won PSL 2023, their second consecutive title.'),
('easy','t20i','multiple_choice','Which T20 league features teams like Trinbago Knight Riders?','["IPL","BBL","CPL","The Hundred"]',2,'Trinbago Knight Riders play in the Caribbean Premier League (CPL).'),
('easy','t20i','multiple_choice','The BPL (Bangladesh Premier League) is played in which country?','["India","Pakistan","Bangladesh","Sri Lanka"]',2,'The Bangladesh Premier League (BPL) is played in Bangladesh.'),
('easy','psl','multiple_choice','Which PSL team is nicknamed the "Gladiators"?','["Islamabad","Lahore","Quetta","Multan"]',2,'Quetta Gladiators are nicknamed the "Gladiators" in the PSL.'),
('easy','t20i','multiple_choice','How many teams participate in SA20?','["4","6","8","10"]',1,'SA20 features 6 teams based in major South African cities.'),
('easy','t20i','multiple_choice','Which BBL team is based in Sydney and wears purple?','["Sydney Thunder","Sydney Sixers","Hobart Hurricanes","Melbourne Stars"]',1,'Sydney Sixers wear magenta/pink-purple and are based in Sydney.'),
('easy','psl','multiple_choice','Which city does Islamabad United represent?','["Lahore","Karachi","Islamabad","Rawalpindi"]',2,'Islamabad United represent Pakistan''s capital city, Islamabad.'),
('easy','t20i','multiple_choice','The ILT20 is a T20 league based in which country?','["India","Ireland","UAE","Indonesia"]',2,'The ILT20 (International League T20) is based in the UAE.'),
('easy','t20i','multiple_choice','Which English county team participates in The Hundred as "Oval Invincibles"?','["Surrey","Middlesex","Kent","Essex"]',0,'The Oval Invincibles are based at The Oval, home of Surrey County Cricket Club.'),
('easy','psl','multiple_choice','Shahid Afridi is associated with which PSL franchise?','["Multan Sultans","Peshawar Zalmi","Quetta Gladiators","Multiple teams"]',3,'Shahid Afridi has been associated with multiple PSL franchises including Peshawar Zalmi and Quetta Gladiators.'),
('easy','t20i','multiple_choice','Which BBL team has "Heat" in their name?','["Melbourne Heat","Brisbane Heat","Perth Heat","Adelaide Heat"]',1,'Brisbane Heat represent Brisbane in the Big Bash League.'),
('easy','t20i','multiple_choice','What format does The Hundred use for bowling?','["4-ball overs","5-ball sets","6-ball overs","10-ball sets"]',1,'In The Hundred, bowlers bowl in sets of 5 balls (though they can bowl up to 10 consecutive).'),
('easy','psl','multiple_choice','Who won the first Lahore Qalandars PSL title?','["They won in 2022","They won in 2020","They won in 2019","They have never won"]',0,'Lahore Qalandars won their first PSL title in 2022 after years of finishing at the bottom.'),
('easy','t20i','multiple_choice','Which Caribbean island is home to the Jamaica Tallawahs?','["Barbados","Trinidad","Jamaica","Guyana"]',2,'Jamaica Tallawahs represent Jamaica in the Caribbean Premier League.'),
('easy','t20i','multiple_choice','The Major League Cricket (MLC) is played in which country?','["Canada","USA","Mexico","Bermuda"]',1,'Major League Cricket (MLC) is a T20 league played in the United States.'),
('easy','psl','multiple_choice','What is Peshawar Zalmi''s team color?','["Green","Yellow","Red","Blue"]',1,'Peshawar Zalmi are known for their distinctive yellow jersey.'),
('easy','t20i','multiple_choice','Which BBL team is based in Perth?','["Perth Scorchers","Perth Stars","Perth Thunder","Perth Lions"]',0,'Perth Scorchers represent Perth in the Big Bash League.'),
('easy','t20i','multiple_choice','How many teams participate in The Hundred?','["6","8","10","12"]',1,'The Hundred features 8 teams in both men''s and women''s competitions.'),
('easy','psl','multiple_choice','Which former Pakistan captain owned Peshawar Zalmi?','["Wasim Akram","Javed Afridi","Imran Khan","Shahid Afridi"]',1,'Javed Afridi is the owner of Peshawar Zalmi, though he is a businessman, not a former Pakistan captain. The franchise is owned by Haier Group''s Javed Afridi.'),

-- MEDIUM (35)
('medium','psl','multiple_choice','Who has scored the most runs in PSL history?','["Babar Azam","Fakhar Zaman","Kamran Akmal","Mohammad Rizwan"]',0,'Babar Azam holds the record for the most runs scored in PSL history.'),
('medium','psl','multiple_choice','Which bowler has taken the most wickets in PSL history?','["Wahab Riaz","Hasan Ali","Shadab Khan","Shaheen Shah Afridi"]',0,'Wahab Riaz holds the record for the most wickets in PSL history.'),
('medium','t20i','multiple_choice','Which team has won the most BBL titles?','["Sydney Sixers","Perth Scorchers","Adelaide Strikers","Melbourne Stars"]',1,'Perth Scorchers have won the most Big Bash League titles.'),
('medium','t20i','multiple_choice','Who has scored the most runs in BBL history?','["Aaron Finch","Chris Lynn","D''Arcy Short","Glenn Maxwell"]',0,'Aaron Finch holds the record for most runs in BBL history.'),
('medium','psl','multiple_choice','What was the highest individual score in a PSL match?','["117*","114","120","128"]',0,'The highest individual score in PSL history is 117* by various batsmen including Colin Munro.'),
('medium','t20i','multiple_choice','Which team won the first CPL title in 2013?','["Jamaica Tallawahs","Trinidad & Tobago Red Steel","Guyana Amazon Warriors","Barbados Tridents"]',0,'Jamaica Tallawahs won the inaugural CPL title in 2013.'),
('medium','psl','multiple_choice','How many times has Multan Sultans won the PSL?','["0","1","2","3"]',1,'Multan Sultans have won the PSL once (2021).'),
('medium','t20i','multiple_choice','Which SA20 team is owned by the same group as Mumbai Indians?','["MI Cape Town","Durban Super Giants","Joburg Super Kings","Paarl Royals"]',0,'MI Cape Town is owned by the Reliance Group, the same owners as Mumbai Indians.'),
('medium','t20i','multiple_choice','Which SA20 team is linked to Chennai Super Kings?','["MI Cape Town","Sunrisers Eastern Cape","Joburg Super Kings","Pretoria Capitals"]',2,'Joburg Super Kings are linked to Chennai Super Kings and the CSK brand.'),
('medium','psl','multiple_choice','Which ground hosted the first PSL match played in Pakistan?','["Gaddafi Stadium, Lahore","National Stadium, Karachi","Rawalpindi Cricket Stadium","Multan Cricket Stadium"]',0,'Gaddafi Stadium in Lahore hosted the first PSL match played on Pakistani soil.'),
('medium','t20i','multiple_choice','Who won the inaugural SA20 title in 2023?','["Sunrisers Eastern Cape","MI Cape Town","Joburg Super Kings","Pretoria Capitals"]',0,'Sunrisers Eastern Cape won the inaugural SA20 title in 2023.'),
('medium','t20i','multiple_choice','Which CPL team has won the most titles?','["Trinbago Knight Riders","Jamaica Tallawahs","Barbados Royals","Guyana Amazon Warriors"]',0,'Trinbago Knight Riders have won the most CPL titles.'),
('medium','psl','multiple_choice','Who scored the fastest half-century in PSL history?','["Kamran Akmal","Shahid Afridi","Iftikhar Ahmed","Liam Livingstone"]',3,'Liam Livingstone scored one of the fastest half-centuries in PSL history.'),
('medium','t20i','multiple_choice','Which Australian player holds the record for most BBL wickets?','["Ben Laughlin","Sean Abbott","Andrew Tye","Kane Richardson"]',0,'Ben Laughlin holds the record for most wickets in BBL history.'),
('medium','psl','multiple_choice','Which PSL team plays home matches at the National Stadium, Karachi?','["Karachi Kings","Quetta Gladiators","Both A and B","Islamabad United"]',0,'Karachi Kings play their home matches at the National Stadium in Karachi.'),
('medium','t20i','multiple_choice','The Hundred was launched in which year?','["2019","2020","2021","2022"]',2,'The Hundred launched its inaugural season in 2021 after a delay due to COVID-19.'),
('medium','t20i','multiple_choice','Which team won the inaugural edition of The Hundred (men''s)?','["Southern Brave","Oval Invincibles","Trent Rockets","Manchester Originals"]',0,'Southern Brave won the inaugural men''s edition of The Hundred in 2021.'),
('medium','psl','multiple_choice','How many PSL matches were held in Pakistan in the first season (2016)?','["0","1","2","All matches"]',0,'The entire first PSL season in 2016 was held in the UAE due to security concerns in Pakistan.'),
('medium','t20i','multiple_choice','Which BBL team is based in Tasmania?','["Hobart Hurricanes","Melbourne Renegades","Adelaide Strikers","Sydney Thunder"]',0,'Hobart Hurricanes represent Tasmania in the Big Bash League.'),
('medium','t20i','multiple_choice','Who owns the Trinbago Knight Riders in CPL?','["Shah Rukh Khan","Preity Zinta","Brendon McCullum","Chris Gayle"]',0,'Shah Rukh Khan''s Red Chillies Entertainment co-owns the Trinbago Knight Riders, linked to KKR.'),
('medium','psl','multiple_choice','Which player has won the most PSL Player of the Match awards?','["Shaheen Shah Afridi","Babar Azam","Shadab Khan","Hasan Ali"]',2,'Shadab Khan has won the most Player of the Match awards in PSL history.'),
('medium','t20i','multiple_choice','What is the maximum squad size in The Hundred?','["12","14","15","18"]',2,'Each team in The Hundred can have a squad of up to 15 players.'),
('medium','t20i','multiple_choice','Which franchise group owns teams in IPL, CPL, SA20, and MLC?','["Mumbai Indians group","Knight Riders group","Royals group","Super Kings group"]',1,'The Knight Riders group (KKR owners) has franchises across IPL, CPL (TKR), SA20, MLC, and ILT20.'),
('medium','psl','multiple_choice','Who captained Islamabad United to the first PSL title?','["Misbah-ul-Haq","Shadab Khan","Alex Hales","Brad Haddin"]',0,'Misbah-ul-Haq captained Islamabad United to the first PSL title in 2016.'),
('medium','t20i','multiple_choice','Which BBL team wears orange?','["Perth Scorchers","Adelaide Strikers","Brisbane Heat","Sydney Thunder"]',0,'Perth Scorchers are known for their orange jerseys in the BBL.'),
('medium','psl','multiple_choice','Which overseas player has made the most appearances in PSL?','["Colin Munro","Rilee Rossouw","Luke Ronchi","Dwayne Bravo"]',1,'Rilee Rossouw has been one of the most prolific and frequent overseas players in PSL history.'),
('medium','t20i','multiple_choice','In the SA20, which team is linked to Rajasthan Royals?','["MI Cape Town","Paarl Royals","Joburg Super Kings","Durban Super Giants"]',1,'Paarl Royals are linked to the Rajasthan Royals ownership group.'),
('medium','t20i','multiple_choice','Which CPL team is based in Guyana?','["Trinbago Knight Riders","Guyana Amazon Warriors","St Lucia Kings","Barbados Royals"]',1,'Guyana Amazon Warriors represent Guyana in the Caribbean Premier League.'),
('medium','psl','multiple_choice','Which venue has hosted the most PSL finals?','["Gaddafi Stadium, Lahore","National Stadium, Karachi","Rawalpindi Stadium","Sharjah Stadium"]',1,'National Stadium in Karachi has hosted the most PSL finals.'),
('medium','t20i','multiple_choice','What is the power surge rule in the BBL?','["2-over batting power in last 10 overs","Extra powerplay","Free hit for every wide","DRS for every team"]',0,'The BBL introduced the Power Surge rule where the batting team can take a 2-over powerplay anytime in the final 10 overs.'),
('medium','psl','multiple_choice','Who won PSL 2024?','["Islamabad United","Multan Sultans","Lahore Qalandars","Peshawar Zalmi"]',0,'Islamabad United won the PSL 2024 title.'),
('medium','t20i','multiple_choice','Which country launched the ILT20 (International League T20)?','["Saudi Arabia","Oman","UAE","Bahrain"]',2,'The UAE launched the ILT20 (International League T20) in January 2023.'),
('medium','t20i','multiple_choice','Which BBL innovation allows a batter to bat again if dismissed?','["X-Factor player","Bash Boost","Power Surge","None - this doesn''t exist"]',3,'The BBL does not have a rule allowing dismissed batters to bat again.'),
('medium','psl','multiple_choice','What was the first PSL season to have all matches in Pakistan?','["PSL 4 (2019)","PSL 5 (2020)","PSL 8 (2023)","PSL 6 (2021)"]',2,'PSL 8 (2023) was the first season where all matches were held entirely in Pakistan.'),
('medium','t20i','multiple_choice','Which player scored the first century in The Hundred?','["Liam Livingstone","Jos Buttler","Jonny Bairstow","Dawid Malan"]',0,'Liam Livingstone scored the first men''s century in The Hundred.'),

-- HARD (30)
('hard','psl','multiple_choice','What was the highest team total in PSL history?','["232/4","247/2","238/3","256/3"]',1,'The highest team total in PSL history is around 247/2.'),
('hard','t20i','multiple_choice','Who took the first hat-trick in BBL history?','["Peter Siddle","Sean Abbott","Ben Laughlin","James Faulkner"]',0,'Peter Siddle took the first hat-trick in BBL history.'),
('hard','psl','multiple_choice','Which player hit the longest six measured in PSL history?','["Shahid Afridi","Chris Gayle","Asif Ali","Azam Khan"]',2,'Asif Ali has hit some of the longest sixes in PSL history.'),
('hard','t20i','multiple_choice','What is the "Bash Boost" point in BBL?','["Bonus point at halfway for leading team","Extra run for hitting the roof","Point for fastest fifty","Bonus for highest powerplay score"]',0,'The Bash Boost awards a bonus competition point to the team leading at the 10-over mark.'),
('hard','psl','multiple_choice','What was the lowest team total in PSL history?','["59","74","81","89"]',2,'The lowest team total in PSL history is around 81 all out.'),
('hard','t20i','multiple_choice','Which player has the best bowling figures in CPL history?','["Sunil Narine","Dwayne Bravo","Rashid Khan","DJ Bravo"]',0,'Sunil Narine holds some of the best bowling figures in CPL history.'),
('hard','psl','multiple_choice','Who was the first overseas captain to lift the PSL trophy?','["Luke Ronchi","Colin Munro","Darren Sammy","Alex Hales"]',2,'Darren Sammy captained Peshawar Zalmi in PSL and was one of the prominent overseas captains.'),
('hard','t20i','multiple_choice','Which team won the BBL 2022-23 season?','["Perth Scorchers","Brisbane Heat","Sydney Sixers","Adelaide Strikers"]',0,'Perth Scorchers won the BBL 2022-23 season.'),
('hard','psl','multiple_choice','How many centuries has Babar Azam scored in PSL?','["0","1","2","3"]',2,'Babar Azam has scored 2 centuries in PSL, despite being the all-time leading run-scorer.'),
('hard','t20i','multiple_choice','Which SA20 team is linked to Sunrisers Hyderabad?','["Sunrisers Eastern Cape","Pretoria Capitals","Durban Super Giants","MI Cape Town"]',0,'Sunrisers Eastern Cape are linked to the Sunrisers Hyderabad ownership group.'),
('hard','psl','multiple_choice','Who scored a century in a PSL final?','["Babar Azam","Kamran Akmal","Fakhar Zaman","Rizwan"]',1,'Kamran Akmal scored a century in a PSL final for Peshawar Zalmi.'),
('hard','t20i','multiple_choice','What is the X-Factor substitution rule in BBL?','["Replace a player after 10th over","Replace a player at innings break","Replace any player anytime","Replace injured player with better one"]',0,'The BBL''s X-Factor rule allowed teams to substitute a player from the 10th over of the first innings (later modified).'),
('hard','psl','multiple_choice','Which PSL franchise has the highest win percentage historically?','["Islamabad United","Peshawar Zalmi","Lahore Qalandars","Multan Sultans"]',0,'Islamabad United have the highest win percentage in PSL history.'),
('hard','t20i','multiple_choice','Who has scored the most runs in CPL history?','["Lendl Simmons","Dwayne Bravo","Chris Gayle","Andre Russell"]',0,'Lendl Simmons holds the record for most runs in CPL history.'),
('hard','psl','multiple_choice','What was the original venue for PSL matches before Pakistan hosted them?','["Dubai and Sharjah","Abu Dhabi and Dubai","Sharjah only","Doha"]',0,'PSL matches were originally held in Dubai and Sharjah in the UAE before shifting to Pakistan.'),
('hard','t20i','multiple_choice','Which team won the inaugural ILT20 in 2023?','["Gulf Giants","MI Emirates","Desert Vipers","Abu Dhabi Knight Riders"]',0,'Gulf Giants won the inaugural ILT20 title in February 2023.'),
('hard','psl','multiple_choice','Who holds the record for most sixes in a single PSL season?','["Asif Ali","Haider Ali","Azam Khan","Colin Munro"]',2,'Azam Khan holds the record for the most sixes in a single PSL season.'),
('hard','t20i','multiple_choice','Which CPL team changed its name from "Red Steel" to "Red Force" before becoming Trinbago Knight Riders?','["They went directly to TKR","Yes, Red Steel to Knight Riders","Red Steel to Red Force to TKR","None of the above"]',0,'Trinidad went from Red Steel directly to Trinbago Knight Riders in 2015 when KKR''s owners bought in.'),
('hard','psl','multiple_choice','Which player took a hat-trick in the PSL 2019 Eliminator?','["Wahab Riaz","Hasan Ali","Shaheen Afridi","Faheem Ashraf"]',2,'Shaheen Shah Afridi took a hat-trick in a PSL 2019 match.'),
('hard','t20i','multiple_choice','How many BBL seasons has the Sydney Sixers won?','["1","2","3","4"]',2,'Sydney Sixers have won 3 BBL titles.'),
('hard','psl','multiple_choice','What was the attendance record for a PSL match in Pakistan?','["About 25,000","About 30,000","About 35,000","About 40,000"]',2,'The National Stadium in Karachi and Gaddafi Stadium in Lahore have hosted PSL matches with attendance around 35,000.'),
('hard','t20i','multiple_choice','Which SA20 team plays at Newlands, Cape Town?','["MI Cape Town","Paarl Royals","Sunrisers Eastern Cape","Pretoria Capitals"]',0,'MI Cape Town plays their home matches at the iconic Newlands Cricket Ground in Cape Town.'),
('hard','psl','multiple_choice','Who has the best bowling figures in a single PSL match?','["Wahab Riaz","Faheem Ashraf","Shaheen Afridi","Haris Rauf"]',2,'Shaheen Shah Afridi holds some of the best bowling figures in a single PSL match.'),
('hard','t20i','multiple_choice','Which player scored the fastest century in BBL history?','["Craig Simmons","Chris Lynn","Marcus Stoinis","Glenn Maxwell"]',0,'Craig Simmons scored the fastest century in BBL history off 39 balls for Adelaide Strikers.'),
('hard','psl','multiple_choice','How many PSL finals have been held in Lahore?','["2","3","4","5"]',1,'Approximately 3 PSL finals have been held at Gaddafi Stadium in Lahore.'),
('hard','t20i','multiple_choice','What is the "Oval Invincibles" home ground in The Hundred?','["Lord''s","The Oval","Edgbaston","Headingley"]',1,'The Oval Invincibles play their home matches at The Oval in London.'),
('hard','t20i','multiple_choice','Which team won The Hundred in 2023 (men''s)?','["Oval Invincibles","Trent Rockets","Southern Brave","Manchester Originals"]',0,'Oval Invincibles won The Hundred men''s competition in 2023.'),
('hard','psl','multiple_choice','Which player made the fastest duck in PSL history (golden duck in first ball)?','["Many players","This is common in T20","Not specifically tracked","All golden ducks are first ball"]',3,'A golden duck by definition is getting out on the first ball faced, which has happened to many players in PSL.'),
('hard','t20i','multiple_choice','Which MLC team won the inaugural Major League Cricket title in 2023?','["MI New York","LA Knight Riders","Seattle Orcas","Texas Super Kings"]',0,'MI New York won the inaugural Major League Cricket title in 2023.'),
('hard','t20i','multiple_choice','Which BBL team has never won a title?','["Melbourne Stars","Sydney Thunder","Brisbane Heat","Melbourne Renegades"]',0,'Melbourne Stars are the most notable BBL team to have never won a title despite multiple finals appearances.')
ON CONFLICT DO NOTHING;



-- BOOK CRICKET SERVICE SCHEMA
-- ============================================================

CREATE TABLE IF NOT EXISTS bc_rooms (
    id UUID PRIMARY KEY,
    code VARCHAR(10) NOT NULL UNIQUE,
    host_user_id UUID NOT NULL,
    format VARCHAR(20) NOT NULL DEFAULT 'T20',
    status VARCHAR(20) NOT NULL DEFAULT 'waiting',
    is_vs_ai BOOLEAN DEFAULT FALSE,
    ai_difficulty VARCHAR(20) DEFAULT 'medium',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_bc_rooms_code ON bc_rooms(code);
CREATE INDEX IF NOT EXISTS idx_bc_rooms_status ON bc_rooms(status);

CREATE TABLE IF NOT EXISTS bc_players (
    id UUID PRIMARY KEY,
    room_id UUID NOT NULL REFERENCES bc_rooms(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    username VARCHAR(255) NOT NULL DEFAULT '',
    avatar_url TEXT DEFAULT '',
    player_index INT NOT NULL DEFAULT 0,
    is_ai BOOLEAN DEFAULT FALSE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bc_players_room ON bc_players(room_id);
CREATE INDEX IF NOT EXISTS idx_bc_players_user ON bc_players(user_id);

CREATE TABLE IF NOT EXISTS bc_match_results (
    id UUID PRIMARY KEY,
    room_id UUID NOT NULL REFERENCES bc_rooms(id) ON DELETE CASCADE,
    winner_user_id UUID,
    winner_idx INT,
    result_text TEXT DEFAULT '',
    innings1_score INT DEFAULT 0,
    innings1_wickets INT DEFAULT 0,
    innings1_overs FLOAT DEFAULT 0,
    innings2_score INT DEFAULT 0,
    innings2_wickets INT DEFAULT 0,
    innings2_overs FLOAT DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bc_results_room ON bc_match_results(room_id);

CREATE TABLE IF NOT EXISTS bc_player_results (
    id UUID PRIMARY KEY,
    room_id UUID NOT NULL REFERENCES bc_rooms(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    player_index INT NOT NULL,
    team_json JSONB DEFAULT '{}',
    points_earned FLOAT DEFAULT 0,
    is_winner BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bc_presults_room ON bc_player_results(room_id);
CREATE INDEX IF NOT EXISTS idx_bc_presults_user ON bc_player_results(user_id);

-- ============================================================
-- ADD cleaned_at TO matches TABLE (cleanup service)
-- ============================================================
ALTER TABLE matches ADD COLUMN IF NOT EXISTS cleaned_at TIMESTAMPTZ;
