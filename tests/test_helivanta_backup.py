import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]


class HelivantaBackupTest(unittest.TestCase):
    def test_backup_is_immediate_scheduled_and_uses_dedicated_identity(self):
        rendered = subprocess.check_output(
            ["helm", "template", "helivanta-postgres", str(ROOT / "charts/apps/helivanta-postgres")],
            text=True,
        )
        resources = [item for item in yaml.safe_load_all(rendered) if item]
        cluster = next(item for item in resources if item["kind"] == "Cluster")["spec"]
        self.assertEqual(cluster["backup"]["retentionPolicy"], "30d")
        self.assertEqual(
            cluster["backup"]["barmanObjectStore"]["destinationPath"],
            "gs://tesseracthub-480811-helivanta-backups-prod/cnpg",
        )
        self.assertEqual(
            cluster["serviceAccountTemplate"]["metadata"]["annotations"]["iam.gke.io/gcp-service-account"],
            "helivanta-db-backup@tesseracthub-480811.iam.gserviceaccount.com",
        )
        schedule = next(item for item in resources if item["kind"] == "ScheduledBackup")["spec"]
        self.assertTrue(schedule["immediate"])
        self.assertEqual(schedule["schedule"], "0 0 */6 * * *")
        policy = next(item for item in resources if item["kind"] == "NetworkPolicy")["spec"]
        self.assertEqual(policy["podSelector"]["matchLabels"], {"cnpg.io/cluster": "helivanta-postgres"})
        self.assertEqual(policy["policyTypes"], ["Egress"])
        self.assertEqual(len(policy["egress"]), 2)


if __name__ == "__main__":
    unittest.main()
