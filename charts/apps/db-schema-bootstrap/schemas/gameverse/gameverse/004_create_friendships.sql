-- liquibase formatted sql
-- changeset gameverse:004-create-friendships

CREATE TABLE friendships (
    player_id       UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    friend_id       UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'blocked')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (player_id, friend_id)
);

CREATE INDEX idx_friendships_friend ON friendships (friend_id);
CREATE INDEX idx_friendships_status ON friendships (status) WHERE status = 'pending';

-- Prevent self-friendship
ALTER TABLE friendships ADD CONSTRAINT chk_no_self_friend CHECK (player_id <> friend_id);

COMMENT ON TABLE friendships IS 'Player friendship/block relationships';
