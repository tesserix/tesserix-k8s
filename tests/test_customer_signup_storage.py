from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_signup_command_schema_preserves_identity_and_opaque_receipt_bounds():
    sql = (ROOT / 'charts/apps/db-schema-bootstrap/schemas/global/global/onboarding_db.sql').read_text()
    assert 'CREATE TABLE IF NOT EXISTS customer_signups (' in sql
    table = sql.split('CREATE TABLE IF NOT EXISTS customer_signups (', 1)[1].split('\n);', 1)[0]
    for column in ('receipt_hash', 'intent_hash', 'owner_email_hash'):
        assert f'octet_length({column}) = 32' in table
    for forbidden in ('password', 'verification_code', 'receipt_token'):
        assert forbidden not in table
    assert 'UNIQUE' in table
    assert 'FOR EACH ROW EXECUTE FUNCTION preserve_customer_signup_intent()' in sql
    assert "state IN ('recorded','identity_requested','existing_account','needs_support','ready')" in table
    assert "WHERE state IN ('recorded','identity_requested')" in sql


def test_existing_owner_binding_preserves_signup_intent_and_new_owner_uniqueness():
    sql = (ROOT / 'charts/apps/db-schema-bootstrap/schemas/global/global/onboarding_db.sql').read_text()
    assert "ADD COLUMN IF NOT EXISTS existing_owner_subject" in sql
    assert "ADD COLUMN IF NOT EXISTS existing_owner_auth_time" in sql
    assert "customer_signup_existing_owner_guard" in sql
    assert "OLD.existing_owner_subject <> ''" in sql
    assert "OLD.state <> 'existing_account'" in sql
    assert "current_setting('app.customer_signup_existing_owner', true)" in sql
    assert "WHERE state <> 'existing_account' AND existing_owner_subject = ''" in sql
    assert "DROP INDEX IF EXISTS customer_signups_email_reservation" in sql
def test_native_email_acceptance_keeps_only_nonsecret_evidence():
    sql = (ROOT / "charts/apps/db-schema-bootstrap/schemas/global/global/onboarding_db.sql").read_text()
    assert "ADD COLUMN IF NOT EXISTS email_accepted_at TIMESTAMPTZ" in sql
    assert "ADD COLUMN IF NOT EXISTS email_provider_id TEXT" in sql
    assert "customer_signup_email_acceptance_evidence" in sql
    assert "email_accepted_at IS NULL" in sql
    assert "email_provider_id = ''" in sql
    assert "email_provider_id ~ '^[A-Za-z0-9_-]{1,200}$'" in sql
    assert "OLD.email_accepted_at IS NOT NULL" in sql
    assert "FOR EACH ROW EXECUTE FUNCTION preserve_customer_signup_email_acceptance()" in sql
