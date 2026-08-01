-- ===========================================================================
-- the event outbox (ADR-0002)
-- ===========================================================================

-- The one table every module writes, and the single exception to ADR-0001's
-- one-writer rule: the outbox is infrastructure, not a domain.
--
-- The rule it exists to enforce is that the state change and the event are one
-- transaction. A handler that publishes after committing loses the event
-- whenever the process dies in between, and that gap is not theoretical — it is
-- every rolling restart.
CREATE TABLE IF NOT EXISTS outbox (
    id              text PRIMARY KEY,
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    type            text NOT NULL,
    version         int  NOT NULL DEFAULT 1,
    subject_kind    text NOT NULL,
    subject_id      text NOT NULL,
    correlation_id  text NOT NULL,
    causation_id    text,
    actor_kind      text NOT NULL,
    actor_id        uuid,
    occurred_at     timestamptz NOT NULL,
    payload         jsonb NOT NULL,

    -- NULL until the broker has durably acknowledged it. The relay's whole
    -- state machine is this column plus the two below it.
    published_at    timestamptz,
    attempts        int NOT NULL DEFAULT 0,
    last_error      text,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT outbox_type_shape CHECK (type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    CONSTRAINT outbox_version_positive CHECK (version >= 1),
    CONSTRAINT outbox_actor_kind CHECK (actor_kind IN ('user', 'system', 'provider', 'support')),
    -- A user actor with no id names nobody, which is the state a support call
    -- cannot get past.
    CONSTRAINT outbox_user_actor_has_an_id CHECK (actor_kind <> 'user' OR actor_id IS NOT NULL),
    CONSTRAINT outbox_subject_present CHECK (btrim(subject_kind) <> '' AND btrim(subject_id) <> '')
);

COMMENT ON TABLE outbox IS
    'ADR-0002. Domain events, written in the same transaction as the state change they describe and drained to JetStream by the relay.';
COMMENT ON COLUMN outbox.published_at IS
    'When the broker acknowledged it. NULL is the backlog, and its oldest occurred_at is the lag alerted on.';

-- The relay's claim: unpublished, due, and in the order the facts happened.
CREATE INDEX IF NOT EXISTS outbox_unpublished_idx
    ON outbox (next_attempt_at, occurred_at) WHERE published_at IS NULL;
-- Answering "did this ever publish" during a support call, by subject.
CREATE INDEX IF NOT EXISTS outbox_subject_idx
    ON outbox (tenant_id, subject_kind, subject_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS outbox_correlation_idx
    ON outbox (correlation_id, occurred_at);

ALTER TABLE outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE outbox FORCE ROW LEVEL SECURITY;

-- A module writes its own organisation's events and reads them back; the relay
-- runs as the platform session because draining is inherently cross-tenant.
DROP POLICY IF EXISTS outbox_tenant_isolation ON outbox;
CREATE POLICY outbox_tenant_isolation ON outbox
    USING (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()))
    WITH CHECK (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()));

-- An event is a record of something that happened, so it is not deletable by a
-- module. The sandbox purge is the one exception, as everywhere else.
DROP POLICY IF EXISTS outbox_no_delete ON outbox;
CREATE POLICY outbox_no_delete ON outbox AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- Every module appends. Only the platform role marks a row published, because
-- only the relay does.
GRANT SELECT, INSERT ON outbox TO dwellm8_money, dwellm8_lease, dwellm8_identity,
    dwellm8_property, dwellm8_maintenance, dwellm8_community, dwellm8_discovery,
    dwellm8_notify;
GRANT SELECT, INSERT, UPDATE ON outbox TO dwellm8_platform;

