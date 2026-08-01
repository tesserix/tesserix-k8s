-- ===========================================================================
-- eSign docUrl — revocation and access evidence (#212)
-- ===========================================================================
-- The signed URL itself is stateless: an HMAC grant carries the organisation,
-- the document, the transaction and the expiry. These tables hold the two
-- things a signature cannot: which transactions have reached a terminal state
-- before their clock ran out, and who fetched what while the window was open.

-- One row closes the window for one transaction. Written on completion,
-- cancellation, timeout or rejection — first terminal state wins, later
-- reports of the same transaction land on the conflict and change nothing.
CREATE TABLE IF NOT EXISTS esign_docurl_revocations (
    tenant_id   uuid NOT NULL REFERENCES organisations(id),
    txn_id      text NOT NULL,
    reason      text NOT NULL CHECK (reason IN ('completed', 'cancelled', 'timeout', 'rejected')),
    revoked_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, txn_id)
);

ALTER TABLE esign_docurl_revocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE esign_docurl_revocations FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS esign_docurl_revocations_tenant_isolation ON esign_docurl_revocations;
CREATE POLICY esign_docurl_revocations_tenant_isolation ON esign_docurl_revocations
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());
DROP POLICY IF EXISTS esign_docurl_revocations_no_delete ON esign_docurl_revocations;
CREATE POLICY esign_docurl_revocations_no_delete ON esign_docurl_revocations AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
-- A closed window stays closed: the row may not be edited into a different
-- reason or a different transaction after the fact.
DROP POLICY IF EXISTS esign_docurl_revocations_no_update ON esign_docurl_revocations;
CREATE POLICY esign_docurl_revocations_no_update ON esign_docurl_revocations AS RESTRICTIVE FOR UPDATE USING (false);

GRANT SELECT, INSERT ON esign_docurl_revocations TO dwellm8_lease;

-- Every fetch of a docUrl, served or refused. The design lets a signer forward
-- the link to a lawyer during the window; this log is what makes that
-- accountable rather than forbidden, and it is retained as lease evidence.
CREATE TABLE IF NOT EXISTS esign_docurl_access_log (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    txn_id        text NOT NULL,
    document_ref  text NOT NULL,
    source_ip     text NOT NULL,
    user_agent    text NOT NULL,
    outcome       text NOT NULL CHECK (outcome IN ('served', 'refused')),
    fetched_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS esign_docurl_access_log_txn_idx
    ON esign_docurl_access_log (tenant_id, txn_id, fetched_at);

ALTER TABLE esign_docurl_access_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE esign_docurl_access_log FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS esign_docurl_access_log_tenant_isolation ON esign_docurl_access_log;
CREATE POLICY esign_docurl_access_log_tenant_isolation ON esign_docurl_access_log
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());
-- A log somebody can edit is not a log — same rule as kyc_access_log.
DROP POLICY IF EXISTS esign_docurl_access_log_no_delete ON esign_docurl_access_log;
CREATE POLICY esign_docurl_access_log_no_delete ON esign_docurl_access_log AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS esign_docurl_access_log_no_update ON esign_docurl_access_log;
CREATE POLICY esign_docurl_access_log_no_update ON esign_docurl_access_log AS RESTRICTIVE FOR UPDATE USING (false);

GRANT SELECT, INSERT ON esign_docurl_access_log TO dwellm8_lease;
