-- ===========================================================================
-- effective dating (ADR-0008)
-- ===========================================================================

-- "What was the rent in March?" and "who owned this flat when the deposit was
-- taken?" are answered from the primary tables. Not from an audit log — a log
-- records that a row changed, and the question is what the row *said*, which is not
-- reliably reconstructible from a diff.
--
-- The pattern, and every effective-dated table in this schema follows it:
--
--   valid_from  date NOT NULL          inclusive lower bound
--   valid_to    date                   EXCLUSIVE upper bound, NULL = open-ended
--   validity    daterange GENERATED    the canonical interval, never written
--   retired_at  timestamptz            set when a correction replaces this row
--   corrects    uuid                   the row a correction replaces
--
-- Three things about it are load-bearing.
--
-- **Half-open, [from, to).** The successor's valid_from equals the predecessor's
-- valid_to exactly: no gap to leave a date uncovered, no overlap to make two rows
-- true at once, and no "the day before" arithmetic anywhere. Closed intervals force
-- the writer to compute 31 March from 1 April, and every such computation is a place
-- to be wrong across a month boundary or a leap day.
--
-- **Dates, not timestamps.** A rent revision is effective from a date. A timestamp
-- forces a question with no good answer — is 1 April effective at 00:00 IST or
-- 00:00 UTC? — and the two differ by five and a half hours during which the rent is
-- legally one number and technically another. Indian agreements are dated by day.
--
-- delegation_grants (ADR-0005) is timestamptz and is correctly not part of this: an
-- authorisation window is not an effective date. A firm's access begins at a moment
-- and no legal document is dated by it. Assertion 14 splits the two by column type
-- and names the timestamptz tables, so a new one has to argue for itself.
--
-- **validity is generated, so there is exactly one expression.** The exclusion
-- constraint and every as-of query use the same column, which is what makes "an
-- open-ended interval is handled consistently everywhere" a property of the schema
-- rather than a rule people follow. The hand-written predicate —
-- `valid_from <= $1 AND (valid_to IS NULL OR valid_to > $1)` — has two places to get
-- the NULL wrong and one to get the boundary wrong. `validity @> $1::date` has none,
-- and `daterange(from, NULL)` is unbounded above without anybody saying so.
--
-- No SQL helper functions here on purpose. The range operators *are* the helpers:
-- `@>` for as-of, `&&` for overlap, `-|-` for adjacency. A function wrapping them
-- would be a second name for an operator every reader already knows.

-- Who owns a unit, and when they did.
--
-- The first table on the standard, and it is ownership rather than rent because rent
-- belongs to the lease (ADR-0010) and ownership belongs to the property. It answers
-- the second question in the story: who owned this flat when the deposit was taken.
CREATE TABLE IF NOT EXISTS property_ownership (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    property_id   uuid NOT NULL,
    -- NULL means the whole property. A tower owned by one party with two flats sold
    -- off is three rows: the property, and two units that override it.
    unit_id       uuid,
    unit_parent_id uuid,

    -- The owning party. Not an organisation: a flat's owner is a person or a company
    -- who may not have an account here at all, and ADR-0006 already keeps balances
    -- per party rather than per organisation.
    owner_party_id uuid NOT NULL,
    -- Undivided share, in basis points, for a jointly owned flat. 10000 = the whole
    -- of it. An integer of minor units, per ADR-0007: a share expressed as a
    -- percentage in floating point is a share that does not add to 100.
    share_bps     int NOT NULL DEFAULT 10000 CHECK (share_bps > 0 AND share_bps <= 10000),

    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    -- A correction retires the row it replaces rather than editing it. ADR-0008 §5:
    -- a change says the world changed, a correction says our record was wrong, and
    -- the difference cannot be recovered later if it is not recorded now.
    retired_at    timestamptz,
    corrects      uuid REFERENCES property_ownership(id),

    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,

    CONSTRAINT property_ownership_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT property_ownership_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT property_ownership_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    -- The upper bound is exclusive, so an interval must cover at least one day. An
    -- equal pair is empty, and an empty validity satisfies no as-of query while
    -- occupying a row that looks like it should.
    CONSTRAINT property_ownership_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- A correction retires and replaces together. A row that names what it corrects
    -- and is not itself live is a correction of a correction with no way to say which
    -- is current; a retired row that nothing corrects is history nobody can explain.
    CONSTRAINT property_ownership_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE property_ownership IS
    'ADR-0008. Who owned what, and when. Half-open date intervals; corrections retire the row they replace rather than editing it.';
COMMENT ON COLUMN property_ownership.validity IS
    'Generated from valid_from and valid_to. The one expression the exclusion constraint and every as-of query share, so open-ended is handled the same way everywhere.';

-- The no-overlap guarantee, and the story's failure scenario made structural.
--
-- An EXCLUDE constraint rather than a trigger or application logic: a trigger has to
-- read the table it is protecting and is therefore racy under concurrency, which is
-- exactly when two writers revise the same flat. The GiST index makes it a lock on
-- the range, so the second writer waits and then fails.
--
-- WHERE (retired_at IS NULL) is what makes corrections possible at all: a retired
-- row still occupies its interval and must not block its own replacement.
--
-- unit_id is compared with = rather than IS NOT DISTINCT FROM because two rows with
-- a NULL unit_id are both about the whole property and *should* conflict — and =
-- against NULL is unknown, so they would not. The partial-index pair below closes
-- that: one constraint for unit rows, one for property-level rows.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'property_ownership_no_overlap_unit') THEN
        ALTER TABLE property_ownership ADD CONSTRAINT property_ownership_no_overlap_unit
            EXCLUDE USING gist (
                tenant_id WITH =, unit_id WITH =, owner_party_id WITH =, validity WITH &&)
            WHERE (retired_at IS NULL AND unit_id IS NOT NULL);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'property_ownership_no_overlap_property') THEN
        ALTER TABLE property_ownership ADD CONSTRAINT property_ownership_no_overlap_property
            EXCLUDE USING gist (
                tenant_id WITH =, property_id WITH =, owner_party_id WITH =, validity WITH &&)
            WHERE (retired_at IS NULL AND unit_id IS NULL);
    END IF;
END
$$;

-- "Who owns this now", and "who owned it on this date" — the same index serves both,
-- because the second is the first with a different date.
CREATE INDEX IF NOT EXISTS property_ownership_asof_idx
    ON property_ownership USING gist (tenant_id, validity) WHERE retired_at IS NULL;
CREATE INDEX IF NOT EXISTS property_ownership_party_idx
    ON property_ownership (owner_party_id, tenant_id) WHERE retired_at IS NULL;
CREATE INDEX IF NOT EXISTS property_ownership_unit_idx
    ON property_ownership (tenant_id, unit_id) WHERE unit_id IS NOT NULL AND retired_at IS NULL;

-- Stamp the ancillary parent, as ledger_postings and payments do, so the policy never
-- reads units. SECURITY INVOKER for the same fail-closed reason.
CREATE OR REPLACE FUNCTION property_ownership_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.unit_id IS NULL THEN
        NEW.unit_parent_id := NULL;
        RETURN NEW;
    END IF;
    SELECT u.parent_unit_id INTO NEW.unit_parent_id
      FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS property_ownership_parent ON property_ownership;
CREATE TRIGGER property_ownership_parent
    BEFORE INSERT OR UPDATE OF unit_id ON property_ownership
    FOR EACH ROW EXECUTE FUNCTION property_ownership_unit_parent();

-- History is not editable. valid_to may be closed and retired_at may be set — those
-- are the two writes effective dating needs — and nothing else may change, because a
-- row whose amount can be edited in place is a row that never had a history.
CREATE OR REPLACE FUNCTION property_ownership_append_only() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.valid_from <> OLD.valid_from
       OR NEW.owner_party_id <> OLD.owner_party_id
       OR NEW.share_bps <> OLD.share_bps
       OR NEW.property_id <> OLD.property_id
       OR NEW.unit_id IS DISTINCT FROM OLD.unit_id THEN
        RAISE EXCEPTION 'ownership row % may not be edited in place: close it and write the '
                        'successor for a change, or retire it and write the replacement for a '
                        'correction (ADR-0008 §5)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    -- Closing an already-closed interval moves a boundary something downstream has
    -- already reported on.
    IF OLD.valid_to IS NOT NULL AND NEW.valid_to IS DISTINCT FROM OLD.valid_to THEN
        RAISE EXCEPTION 'ownership row % is already closed at %', OLD.id, OLD.valid_to
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.retired_at IS NOT NULL AND NEW.retired_at IS DISTINCT FROM OLD.retired_at THEN
        RAISE EXCEPTION 'ownership row % is already retired', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS property_ownership_no_edit ON property_ownership;
CREATE TRIGGER property_ownership_no_edit
    BEFORE UPDATE ON property_ownership
    FOR EACH ROW EXECUTE FUNCTION property_ownership_append_only();

ALTER TABLE property_ownership ENABLE ROW LEVEL SECURITY;
ALTER TABLE property_ownership FORCE  ROW LEVEL SECURITY;

-- Unit granularity, as ADR-0009 §4 requires and assertion 6 enforces.
DROP POLICY IF EXISTS property_ownership_tenant_isolation ON property_ownership;
CREATE POLICY property_ownership_tenant_isolation ON property_ownership
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'property.write'));

DROP POLICY IF EXISTS property_ownership_no_delete ON property_ownership;
CREATE POLICY property_ownership_no_delete ON property_ownership AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON property_ownership TO dwellm8_property;
GRANT SELECT ON property_ownership TO dwellm8_lease, dwellm8_money, dwellm8_identity;

