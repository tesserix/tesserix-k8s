-- liquibase formatted sql
-- changeset gameverse:001-create-players

CREATE TABLE players (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    keycloak_sub    TEXT UNIQUE NOT NULL,
    username        TEXT UNIQUE NOT NULL,
    display_name    TEXT NOT NULL,
    avatar_url      TEXT,
    rating          JSONB NOT NULL DEFAULT '{}',
    stats           JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_players_keycloak_sub ON players (keycloak_sub);
CREATE INDEX idx_players_username ON players (username);
CREATE INDEX idx_players_last_seen ON players (last_seen_at DESC);

COMMENT ON TABLE players IS 'Player profiles synced from Keycloak';
COMMENT ON COLUMN players.rating IS 'Per-game Glicko-2 ratings: {"ludo": {"r": 1500, "rd": 350, "vol": 0.06}}';
COMMENT ON COLUMN players.stats IS 'Per-game stats: {"ludo": {"wins": 0, "losses": 0, "draws": 0, "matches": 0}}';
