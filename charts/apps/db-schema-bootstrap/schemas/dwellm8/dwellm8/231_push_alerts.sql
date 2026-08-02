-- 231: push alerts (#126 first slice, delivering #144). A prospect's Expo
-- push token — their reachability, platform-held like everything else of
-- theirs — and the alert watermark on saved searches, separate from the
-- user-driven last_seen_at because "I looked" and "we told them" are
-- different facts with different owners.

CREATE TABLE IF NOT EXISTS prospect_push_tokens (
    expo_token   text PRIMARY KEY,
    prospect_id  uuid NOT NULL REFERENCES prospects(id),
    platform     text NOT NULL CHECK (platform IN ('ios', 'android')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    -- Set when Expo answers DeviceNotRegistered: the token is dead, and a
    -- dead token kept live is a push retried forever.
    disabled_at  timestamptz
);

COMMENT ON TABLE prospect_push_tokens IS
    '#126. The token is the key: a device re-registered by a new prospect simply moves.';

CREATE INDEX IF NOT EXISTS prospect_push_tokens_prospect_idx
    ON prospect_push_tokens (prospect_id) WHERE disabled_at IS NULL;

ALTER TABLE prospect_push_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE prospect_push_tokens FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS prospect_push_tokens_platform_only ON prospect_push_tokens;
CREATE POLICY prospect_push_tokens_platform_only ON prospect_push_tokens
    USING (is_platform_session()) WITH CHECK (is_platform_session());

DROP POLICY IF EXISTS prospect_push_tokens_resident_denied ON prospect_push_tokens;
CREATE POLICY prospect_push_tokens_resident_denied ON prospect_push_tokens AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

GRANT SELECT, INSERT, UPDATE, DELETE ON prospect_push_tokens TO dwellm8_discovery;

-- The alert watermark: an alert covers listings published after this, and
-- sending advances it — the no-resend rule for the channel, enforced by the
-- same arithmetic the in-app count uses. Defaults to now() so a search never
-- alerts about what already existed when it was saved.
ALTER TABLE saved_searches ADD COLUMN IF NOT EXISTS
    last_alerted_at timestamptz NOT NULL DEFAULT now();
