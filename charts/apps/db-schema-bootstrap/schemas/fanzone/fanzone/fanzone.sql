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
