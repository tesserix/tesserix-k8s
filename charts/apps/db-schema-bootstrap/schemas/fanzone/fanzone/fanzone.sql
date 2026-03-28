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
