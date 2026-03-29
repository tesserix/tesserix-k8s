-- liquibase formatted sql
-- changeset gameverse:006-create-sessions

-- Session tracking (supplements Redis sessions for auditing)
CREATE TABLE player_sessions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id       UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    ip_address      INET,
    user_agent      TEXT,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at        TIMESTAMPTZ,
    is_active       BOOLEAN NOT NULL DEFAULT true
);

CREATE INDEX idx_sessions_player ON player_sessions (player_id, started_at DESC);
CREATE INDEX idx_sessions_active ON player_sessions (is_active) WHERE is_active = true;

COMMENT ON TABLE player_sessions IS 'Login session audit log — primary sessions managed in Redis';
