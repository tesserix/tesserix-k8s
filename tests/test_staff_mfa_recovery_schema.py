import pathlib
import unittest

SCHEMA = pathlib.Path(__file__).resolve().parents[1] / "charts/apps/db-schema-bootstrap/schemas/global/global/onboarding_db.sql"


class StaffMFARecoverySchema(unittest.TestCase):
    def test_one_physical_subject_has_one_open_recovery_and_indexed_admission(self):
        text = SCHEMA.read_text()
        self.assertIn("CREATE UNIQUE INDEX IF NOT EXISTS staff_mfa_recovery_subject_fence ON staff_mfa_recovery_commands(target_subject)\n    WHERE state IN ('prepared','processing','awaiting_enrollment','unconfirmed')", text)
        self.assertIn("CREATE INDEX IF NOT EXISTS staff_mfa_recovery_subject_generation ON staff_mfa_recovery_commands(target_subject,generation DESC)\n    WHERE state<>'cancelled'", text)

    def test_staff_reset_retains_exact_source_and_precise_native_evidence(self):
        text = SCHEMA.read_text()
        start = text.find("CREATE TABLE IF NOT EXISTS staff_mfa_recovery_commands (")
        self.assertGreaterEqual(start, 0)
        table = text[start:text.index("\n);", start)]
        for clause in [
            "org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT",
            "staff_version BIGINT NOT NULL", "link_id UUID NOT NULL", "link_version BIGINT NOT NULL",
            "employer_kind IN ('hospital','pharmacy','supplier')", "actor_subject <> target_subject",
            "generation BIGINT GENERATED ALWAYS AS IDENTITY", "native_changed_at TEXT", "enrollment_verified_at TEXT",
            "'prepared','processing','awaiting_enrollment','unconfirmed','cancelled','completed'",
            "application_fence_id = id",
        ]:
            self.assertIn(clause, table)
        for secret in ["password TEXT", "totp_secret", "totp_code", "session_token", "session_id"]:
            self.assertNotIn(secret, table)

    def test_uncertain_commands_cannot_expire_replay_or_mutate_target(self):
        text = SCHEMA.read_text()
        self.assertIn("staff_mfa_recovery_account_fence", text)
        self.assertIn("WHERE state IN ('prepared','processing','awaiting_enrollment','unconfirmed')", text)
        self.assertIn("staff_mfa_recovery_latest_generation", text)
        self.assertIn("guard_staff_mfa_recovery_command", text)
        self.assertIn("OLD.state='prepared' AND NEW.state IN ('processing','cancelled')", text)
        self.assertIn("OLD.state='processing' AND NEW.state IN ('awaiting_enrollment','unconfirmed')", text)
        self.assertIn("OLD.state='awaiting_enrollment' AND NEW.state='completed'", text)
        self.assertIn("REVOKE DELETE, TRUNCATE ON staff_mfa_recovery_commands FROM onboarding", text)
        self.assertNotIn("expires_at", text[text.index("CREATE TABLE IF NOT EXISTS staff_mfa_recovery_commands ("):])
