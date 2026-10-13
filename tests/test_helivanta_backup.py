import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]


class HelivantaBackupTest(unittest.TestCase):
    def test_restore_check_has_no_production_volume_or_credentials(self):
        rendered = subprocess.check_output(
            ["helm", "template", "helivanta-postgres", str(ROOT / "charts/apps/helivanta-postgres"),
             "--set", "restoreCheck.enabled=true", "--set-string", "restoreCheck.backupID=20261013T060000"],
            text=True,
        )
        resources = [item for item in yaml.safe_load_all(rendered) if item]
        job = next(item for item in resources if item["kind"] == "Job")
        pod = job["spec"]["template"]["spec"]
        self.assertEqual(pod["serviceAccountName"], "helivanta-restore-check")
        self.assertEqual(pod["restartPolicy"], "Never")
        self.assertTrue(all("persistentVolumeClaim" not in v and "secret" not in v for v in pod["volumes"]))
        self.assertEqual(pod["containers"][0]["securityContext"]["allowPrivilegeEscalation"], False)
        self.assertNotIn("envFrom", pod["containers"][0])

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
