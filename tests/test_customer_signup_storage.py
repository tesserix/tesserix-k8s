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
