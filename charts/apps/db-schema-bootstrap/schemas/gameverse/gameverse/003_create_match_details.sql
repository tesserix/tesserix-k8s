-- liquibase formatted sql
-- changeset gameverse:003-create-match-details

-- Game-specific match analytics (Ludo-specific for now, extensible)
CREATE TABLE match_details (
    match_id        UUID PRIMARY KEY REFERENCES matches(id) ON DELETE CASCADE,
    game_slug       TEXT NOT NULL,
    details         JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX idx_match_details_game ON match_details (game_slug);

COMMENT ON TABLE match_details IS 'Game-specific match analytics (e.g., total captures, sixes rolled)';
COMMENT ON COLUMN match_details.details IS 'Ludo: {"totalRolls": N, "totalCaptures": N, "totalSixes": N, "tokensHome": {"red": 4}, "avgTurnTimeSecs": N}';
