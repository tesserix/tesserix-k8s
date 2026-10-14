import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]


class HelivantaDocumentIdentityTest(unittest.TestCase):
    def test_worker_role_exists_without_login_or_inherited_personnel_access(self):
        rendered = subprocess.check_output(
            ["helm", "template", "helivanta-postgres", str(ROOT / "charts/apps/helivanta-postgres")],
            text=True,
        )
        resources = [item for item in yaml.safe_load_all(rendered) if item]
        cluster = next(item for item in resources if item["kind"] == "Cluster")
        roles = cluster["spec"]["managed"]["roles"]
        workers = [role for role in roles if role["name"] == "helivanta_document_worker"]
        self.assertEqual(len(workers), 1)
        worker = workers[0]
        self.assertEqual(worker["ensure"], "present")
        self.assertFalse(worker["inherit"])
        for privilege in ["login", "inherit", "superuser", "bypassrls", "createdb", "createrole"]:
            self.assertFalse(worker.get(privilege, False), privilege)
        self.assertNotIn("inRoles", worker)
        self.assertNotIn("passwordSecret", worker)


if __name__ == "__main__":
    unittest.main()
