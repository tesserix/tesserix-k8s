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

CREATE TABLE IF NOT EXISTS quiz_questions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    question TEXT NOT NULL,
    options JSONB NOT NULL,
    correct_option INT NOT NULL,
    difficulty VARCHAR(50) NOT NULL DEFAULT 'easy',
    category VARCHAR(100) DEFAULT '',
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
    question_order INT NOT NULL,
    UNIQUE(tournament_id, question_id)
);
CREATE INDEX IF NOT EXISTS idx_quiz_tq_tournament ON quiz_tournament_questions(tournament_id);

CREATE TABLE IF NOT EXISTS quiz_level_progress (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tournament_id UUID NOT NULL REFERENCES quiz_tournaments(id) ON DELETE CASCADE,
    level INT NOT NULL,
    correct_count INT DEFAULT 0,
    wrong_count INT DEFAULT 0,
    total_questions INT NOT NULL,
    max_wrong INT NOT NULL,
    status VARCHAR(50) DEFAULT 'in_progress',
    points_earned FLOAT DEFAULT 0,
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
    selected_option INT NOT NULL,
    is_correct BOOLEAN NOT NULL,
    time_taken_ms INT DEFAULT 0,
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

CREATE TABLE IF NOT EXISTS quiz_user_question_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    question_id UUID NOT NULL REFERENCES quiz_questions(id),
    asked_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, question_id)
);
CREATE INDEX IF NOT EXISTS idx_quiz_hist_user ON quiz_user_question_history(user_id);
