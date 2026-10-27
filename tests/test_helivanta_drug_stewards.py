import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]


class HelivantaDrugStewardsTest(unittest.TestCase):
    def test_steward_roles_exist_without_login_or_shared_membership(self):
        rendered = subprocess.check_output(
            ["helm", "template", "helivanta-postgres", str(ROOT / "charts/apps/helivanta-postgres")],
            text=True,
        )
        resources = [item for item in yaml.safe_load_all(rendered) if item]
        cluster = next(item for item in resources if item["kind"] == "Cluster")
        roles = cluster["spec"]["managed"]["roles"]
        for name in ["helivanta_drug_stager", "helivanta_drug_approver"]:
            matches = [role for role in roles if role["name"] == name]
            self.assertEqual(len(matches), 1, name)
            role = matches[0]
            self.assertEqual(role["ensure"], "present")
            for privilege in ["login", "inherit", "superuser", "bypassrls", "createdb", "createrole"]:
                self.assertFalse(role.get(privilege, False), (name, privilege))
            # Membership in the other role would let one credential do both steps.
            self.assertNotIn("inRoles", role, name)
            self.assertNotIn("passwordSecret", role, name)


if __name__ == "__main__":
    unittest.main()
