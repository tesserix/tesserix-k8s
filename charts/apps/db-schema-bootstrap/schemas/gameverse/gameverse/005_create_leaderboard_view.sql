-- liquibase formatted sql
-- changeset gameverse:005-create-leaderboard-view

CREATE MATERIALIZED VIEW leaderboard AS
SELECT
    p.id AS player_id,
    p.username,
    p.display_name,
    p.avatar_url,
    game.key AS game_slug,
    (game.value->>'r')::FLOAT AS rating,
    (game.value->>'rd')::FLOAT AS rating_deviation,
    COALESCE((p.stats->game.key->>'wins')::INT, 0) AS wins,
    COALESCE((p.stats->game.key->>'losses')::INT, 0) AS losses,
    COALESCE((p.stats->game.key->>'draws')::INT, 0) AS draws,
    COALESCE((p.stats->game.key->>'matches')::INT, 0) AS total_matches
FROM players p,
     LATERAL jsonb_each(p.rating) AS game
WHERE (game.value->>'r')::FLOAT > 0
ORDER BY (game.value->>'r')::FLOAT DESC;

CREATE UNIQUE INDEX idx_leaderboard_pk ON leaderboard (game_slug, player_id);
CREATE INDEX idx_leaderboard_rating ON leaderboard (game_slug, rating DESC);

COMMENT ON MATERIALIZED VIEW leaderboard IS 'Pre-computed leaderboard — refresh with: REFRESH MATERIALIZED VIEW CONCURRENTLY leaderboard;';
