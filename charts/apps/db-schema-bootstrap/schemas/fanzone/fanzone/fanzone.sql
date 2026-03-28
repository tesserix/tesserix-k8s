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

CREATE TABLE IF NOT EXISTS match_commentary_config (
    match_id UUID PRIMARY KEY,
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
    match_id UUID NOT NULL,
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
    match_id UUID NOT NULL,
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
    match_id UUID NOT NULL,
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
    match_id UUID NOT NULL,
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
    match_id UUID NOT NULL,
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
    match_id UUID NOT NULL,
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
