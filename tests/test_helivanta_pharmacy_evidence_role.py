import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]


class HelivantaPharmacyEvidenceRoleTest(unittest.TestCase):
    def test_worker_role_exists_without_login_before_its_migration(self):
        rendered = subprocess.check_output(
            ["helm", "template", "helivanta-postgres", str(ROOT / "charts/apps/helivanta-postgres")],
            text=True,
        )
        resources = [item for item in yaml.safe_load_all(rendered) if item]
        cluster = next(item for item in resources if item["kind"] == "Cluster")
        matches = [role for role in cluster["spec"]["managed"]["roles"] if role["name"] == "helivanta_pharmacy_evidence_worker"]
        self.assertEqual(len(matches), 1)
        role = matches[0]
        self.assertEqual(role["ensure"], "present")
        for privilege in ["login", "inherit", "superuser", "bypassrls", "createdb", "createrole"]:
            self.assertFalse(role.get(privilege, False), privilege)
        # Membership in another role would widen the worker past its one file.
        self.assertNotIn("inRoles", role)
        self.assertNotIn("passwordSecret", role)


if __name__ == "__main__":
    unittest.main()
