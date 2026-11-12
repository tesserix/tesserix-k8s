import pathlib
import unittest

SCHEMA = pathlib.Path(__file__).resolve().parents[1] / 'charts/apps/db-schema-bootstrap/schemas/global/global/onboarding_db.sql'

class AccountDiscoverySchema(unittest.TestCase):
    def test_separate_short_lived_purpose_and_bounded_proof(self):
        text = SCHEMA.read_text()
        self.assertIn('CREATE TABLE IF NOT EXISTS account_discovery_challenges', text)
        for clause in ['octet_length(browser_hash) = 32', 'octet_length(code_hash) = 32', 'attempts BETWEEN 0 AND 5', "INTERVAL '10 minutes'", 'account_discovery_recipient_budget', 'account_discovery_source_budget', 'account_discovery_expiry']:
            self.assertIn(clause, text)
        self.assertIn('registry_credentials, customer_signups, account_discovery_challenges', text)
