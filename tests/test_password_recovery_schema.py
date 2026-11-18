import pathlib
import unittest

SCHEMA = pathlib.Path(__file__).resolve().parents[1] / 'charts/apps/db-schema-bootstrap/schemas/global/global/onboarding_db.sql'

class PasswordRecoverySchema(unittest.TestCase):
    def test_dedicated_tenant_and_browser_bound_mailbox_proof(self):
        text = SCHEMA.read_text()
        start = text.index('CREATE TABLE IF NOT EXISTS password_recovery_challenges (')
        table = text[start:text.index('\n);', start)]
        for clause in ['tenant_id UUID NOT NULL', 'octet_length(browser_hash) = 32', 'octet_length(source_hash) = 32', 'octet_length(code_hash) = 32', 'attempts BETWEEN 0 AND 5', "INTERVAL '10 minutes'", "delivery_outcome IN ('reserved','accepted','unavailable')"]:
            self.assertIn(clause, table)
        for secret in ['password TEXT', 'native_code', 'session_token']:
            self.assertNotIn(secret, table)
        for index in ['password_recovery_recipient_budget', 'password_recovery_source_budget', 'password_recovery_expiry', 'password_recovery_browser_proof']:
            self.assertIn(index, text)
        self.assertIn('guard_password_recovery_challenge', text)
        self.assertIn('GRANT UPDATE (attempts, verified_at, delivery_outcome, updated_at) ON password_recovery_challenges TO onboarding', text)
        self.assertNotIn('customer_signups, account_discovery_challenges, password_recovery_challenges', text)

    def test_cleanup_retains_non_reusable_command_tombstones(self):
        text = SCHEMA.read_text()
        self.assertIn('CREATE TABLE IF NOT EXISTS password_recovery_delivery_ids', text)
        self.assertIn('REFERENCES password_recovery_delivery_ids(id) ON DELETE RESTRICT', text)
        self.assertIn('REVOKE UPDATE, DELETE, TRUNCATE ON password_recovery_delivery_ids FROM onboarding', text)
