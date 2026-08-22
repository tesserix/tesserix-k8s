import pathlib
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
PROD = ROOT / "external-secrets/prod"

# Projects deliberately parked (scaled down, namespace gone) — their manifests
# stay in tree as recovery material and are commented out of the aggregate.
PARKED = {"kargo-fanzone", "kargo-stockpilot", "kargo-gameverse"}


def listed_resources():
    doc = yaml.safe_load((PROD / "kustomization.yaml").read_text())
    return set(doc.get("resources", []))


class KargoGitCredentials(unittest.TestCase):
    # A Warehouse that subscribes to a private repo can clone anonymously only
    # while that repo is public. Every kargo-<project> credential directory must
    # therefore actually be wired into the aggregate, or promotion silently
    # stalls the next time CI returns the repo to private.
    def test_every_kargo_creds_directory_is_listed(self):
        listed = listed_resources()
        for path in sorted(PROD.glob("kargo-*")):
            if not path.is_dir() or path.name in PARKED:
                continue
            self.assertIn(path.name, listed, f"{path.name} exists but is not applied")

    def test_kora_warehouse_has_git_credentials(self):
        doc = yaml.safe_load(
            (PROD / "kargo-kora/kora-git-externalsecret.yaml").read_text()
        )
        self.assertEqual(doc["metadata"]["namespace"], "kargo-kora")
        template = doc["spec"]["target"]["template"]
        self.assertEqual(
            template["metadata"]["labels"]["kargo.akuity.io/cred-type"], "git"
        )
        self.assertEqual(
            template["data"]["repoURL"], "https://github.com/tesserix/kora.git"
        )


if __name__ == "__main__":
    unittest.main()
