-- liquibase formatted sql
-- changeset gameverse:002-create-matches

CREATE TABLE matches (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    game_slug       TEXT NOT NULL,
    room_id         TEXT NOT NULL,
    players         UUID[] NOT NULL,
    winner_id       UUID,
    result          TEXT NOT NULL CHECK (result IN ('win', 'draw', 'abandon')),
    initial_state   JSONB NOT NULL,
    final_state     JSONB NOT NULL,
    moves           JSONB NOT NULL,
    move_count      INT NOT NULL DEFAULT 0,
    started_at      TIMESTAMPTZ NOT NULL,
    ended_at        TIMESTAMPTZ NOT NULL,
    duration_secs   INT GENERATED ALWAYS AS
                    (EXTRACT(EPOCH FROM ended_at - started_at)::INT) STORED
);

CREATE INDEX idx_matches_game_slug ON matches (game_slug, ended_at DESC);
CREATE INDEX idx_matches_players ON matches USING GIN (players);
CREATE INDEX idx_matches_winner ON matches (winner_id) WHERE winner_id IS NOT NULL;
CREATE INDEX idx_matches_room ON matches (room_id);

COMMENT ON TABLE matches IS 'Completed game match records';
COMMENT ON COLUMN matches.moves IS 'Ordered JSON array of all moves made during the match';
