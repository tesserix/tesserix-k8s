-- ===========================================================================
-- demo sandbox (ADR-0021)
-- ===========================================================================

-- The sandbox is an unauthenticated, write-capable surface exposed to the whole internet.
-- Anyone can start a demo with no account, so session identity, isolation, expiry and
-- cost bounds are decided here rather than discovered.
--
-- organisations.is_sandbox has existed since ADR-0003 carrying a promise nothing kept:
-- "Nothing in it may ever cause a side effect: no money moves, no message is sent." This
-- section is what makes that true, and the enforcement is in two halves that hold each
-- other up — see sandbox_purge_permitted() above.

CREATE TABLE IF NOT EXISTS demo_sessions (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The ephemeral organisation this session owns. One per session, never shared: two
    -- visitors editing the same demo is the failure that makes a sandbox worthless.
    tenant_id      uuid NOT NULL UNIQUE REFERENCES organisations(id),

    -- The opaque token, hashed. The token itself is never stored, for the same reason
    -- ADR-0013 stores no full identifier: a database copy would otherwise hand out live
    -- sessions. sha256 rather than a slow hash on purpose — this is a 256-bit random
    -- value, so there is no dictionary to defend against and a slow hash would only make
    -- every request slower.
    token_hash     bytea NOT NULL UNIQUE CHECK (length(token_hash) = 32),

    -- Sliding, so a visitor returning after several days resumes rather than silently
    -- receiving a fresh sandbox with their work gone.
    expires_at     timestamptz NOT NULL,
    -- Absolute. A sliding window with no ceiling is a session that never expires, and
    -- the storage cost of one that never expires is unbounded.
    hard_expires_at timestamptz NOT NULL,

    -- Which template seeded it, so a template change does not silently mean two visitors
    -- saw different products.
    template       text NOT NULL,

    -- Coarse, for the abuse case. Not an address: a /24 or a hashed prefix is enough to
    -- rate-limit on and does not build a log of who visited.
    origin_bucket  text,

    created_at     timestamptz NOT NULL DEFAULT now(),
    last_seen_at   timestamptz NOT NULL DEFAULT now(),
    converted_at   timestamptz,

    CONSTRAINT demo_sessions_window CHECK (
        expires_at > created_at AND hard_expires_at >= expires_at),
    -- A sliding window may not slide past the ceiling, which is what makes the ceiling one.
    CONSTRAINT demo_sessions_ceiling CHECK (hard_expires_at > created_at)
);

COMMENT ON TABLE demo_sessions IS
    'ADR-0021. One ephemeral organisation per visitor. The token is stored hashed; the sliding window resumes, the hard ceiling ends.';

CREATE INDEX IF NOT EXISTS demo_sessions_expiry_idx ON demo_sessions (expires_at);
CREATE INDEX IF NOT EXISTS demo_sessions_origin_idx
    ON demo_sessions (origin_bucket, created_at) WHERE origin_bucket IS NOT NULL;

-- The organisation a demo session points at must actually be a sandbox, or the session
-- is a way to reach a real organisation without an account.
CREATE OR REPLACE FUNCTION demo_sessions_point_at_a_sandbox() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT is_sandbox_tenant(NEW.tenant_id) THEN
        RAISE EXCEPTION 'demo session % points at organisation %, which is not a sandbox — an '
                        'unauthenticated session must not reach a real organisation',
            NEW.id, NEW.tenant_id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS demo_sessions_sandbox_only ON demo_sessions;
CREATE TRIGGER demo_sessions_sandbox_only
    BEFORE INSERT OR UPDATE OF tenant_id ON demo_sessions
    FOR EACH ROW EXECUTE FUNCTION demo_sessions_point_at_a_sandbox();

-- ADR-0021 §3. The side-effect ban, made structural for the one table that can move real
-- money.
--
-- A demo has payments in it — it is a demo of a rent platform — so the rule is not "no
-- payments" but "no payment through a real provider". A sandbox payment names the sandbox
-- adapter and nothing else, so a demo cannot create an order at Razorpay however the code
-- is wired.
--
-- This is the half that makes the purge safe: nothing real originates in a sandbox, so
-- nothing real is lost when one is dropped.
CREATE OR REPLACE FUNCTION payments_sandbox_has_no_real_provider() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF is_sandbox_tenant(NEW.tenant_id) AND NEW.provider <> 'sandbox' THEN
        RAISE EXCEPTION 'payment % is in a sandbox organisation and names provider %: a demo may '
                        'not reach a real payment provider, and the sandbox being purgeable '
                        'depends on it', NEW.id, NEW.provider
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS payments_sandbox_provider ON payments;
CREATE TRIGGER payments_sandbox_provider
    BEFORE INSERT OR UPDATE OF provider, tenant_id ON payments
    FOR EACH ROW EXECUTE FUNCTION payments_sandbox_has_no_real_provider();

-- And the same for a durable operation: a sandbox may not run one that reaches outside.
-- recon.day is platform-wide and never sandbox; everything else on ADR-0015's list either
-- moves money or files a document, so none of them may originate in a demo.
CREATE OR REPLACE FUNCTION workflow_runs_sandbox_has_no_external_effect() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF is_sandbox_tenant(NEW.tenant_id) THEN
        RAISE EXCEPTION 'workflow run % is in a sandbox organisation and runs %: every durable '
                        'operation reaches a provider, a bank or a government gateway, and a demo '
                        'may reach none of them', NEW.id, NEW.operation
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS workflow_runs_sandbox_ban ON workflow_runs;
CREATE TRIGGER workflow_runs_sandbox_ban
    BEFORE INSERT ON workflow_runs
    FOR EACH ROW EXECUTE FUNCTION workflow_runs_sandbox_has_no_external_effect();

-- ADR-0021 §5. The cost bound, as a hard cap on live sandboxes.
--
-- "The cost stays within the stated cap" is only true if something states it and
-- something enforces it. Rate limiting lives at the edge, where it belongs, and it fails
-- open under a distributed attack; this is the floor beneath it, and it fails closed.
--
-- The cap is deliberately in the schema rather than in configuration: a number an
-- operator can raise under pressure at 3am is a number that gets raised.
CREATE OR REPLACE FUNCTION demo_sessions_within_the_cap() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    live int;
    cap  CONSTANT int := 500;
BEGIN
    SELECT count(*) INTO live FROM demo_sessions WHERE expires_at > now();
    IF live >= cap THEN
        RAISE EXCEPTION 'the demo sandbox is at its cap of % live sessions: creation is bounded so '
                        'a script cannot make the storage cost unbounded, and existing sessions are '
                        'unaffected', cap
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS demo_sessions_cap ON demo_sessions;
CREATE TRIGGER demo_sessions_cap
    BEFORE INSERT ON demo_sessions
    FOR EACH ROW EXECUTE FUNCTION demo_sessions_within_the_cap();

ALTER TABLE demo_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE demo_sessions FORCE  ROW LEVEL SECURITY;

-- The session row is the platform's: it is created before there is a tenant to scope to,
-- and it holds the token hash. A demo session reads its own *organisation's* data through
-- ordinary tenancy, exactly as a real one does — which is the point of §6. It never reads
-- this table.
DROP POLICY IF EXISTS demo_sessions_platform_only ON demo_sessions;
CREATE POLICY demo_sessions_platform_only ON demo_sessions
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

-- Deletable, unlike everything else in this schema, and by the same rule: it is the
-- sandbox's own record.
DROP POLICY IF EXISTS demo_sessions_purgeable ON demo_sessions;
CREATE POLICY demo_sessions_purgeable ON demo_sessions AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON demo_sessions TO dwellm8_identity;

