-- ===========================================================================
-- owner pre-onboarding, and a name people give themselves (#240)
-- ===========================================================================

-- An owner's identity can now exist before they do — the manager types their
-- number the way a landlord types a tenant's (ADR-0029 backwards-arrival,
-- reused whole). The only schema this needs is a display name: the person
-- fills in their own PI after the fact, and the verified phone stays the
-- anchor nobody edits.

ALTER TABLE identity_principals ADD COLUMN IF NOT EXISTS display_name text;

COMMENT ON COLUMN identity_principals.display_name IS
    '#240. What the person calls themselves, self-served after onboarding. Never an identifier — phone and email are.';
