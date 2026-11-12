from pathlib import Path
import hashlib
import tarfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHARTS = ROOT / "charts/thirdparty/istio-release"


class IstioReleaseChartsTests(unittest.TestCase):
    def test_release_index_contains_verified_complete_chart_set(self):
        index = yaml.safe_load((CHARTS / "index.yaml").read_text())
        self.assertEqual(
            set(index["entries"]), {"base", "istiod", "cni", "ztunnel", "gateway"}
        )
        for name, entries in index["entries"].items():
            self.assertEqual(len(entries), 1)
            entry = entries[0]
            self.assertEqual(entry["version"], "1.31.4")
            archive = CHARTS / f"{name}-1.31.4.tgz"
            self.assertEqual(
                hashlib.sha256(archive.read_bytes()).hexdigest(), entry["digest"]
            )
            self.assertEqual(
                entry["urls"],
                [
                    f"https://raw.githubusercontent.com/tesserix/tesserix-k8s/main/charts/thirdparty/istio-release/{archive.name}"
                ],
            )
            with tarfile.open(archive) as contents:
                for member in contents.getmembers():
                    self.assertFalse(member.name.startswith("/"))
                    self.assertNotIn("..", Path(member.name).parts)
                    self.assertFalse(member.issym() or member.islnk())
                metadata = yaml.safe_load(contents.extractfile(f"{name}/Chart.yaml"))
                self.assertEqual(metadata["name"], name)
                self.assertEqual(metadata["version"], "1.31.4")


if __name__ == "__main__":
    unittest.main()
