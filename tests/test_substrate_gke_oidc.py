import pathlib
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
SUBSTRATE_VERSION = "0.0.8"
SUBSTRATE_WORKER_DIGEST = (
    "sha256:8462988e405a2e2323716751b1c12da808e084e7911a1c34cde710a23e0a5090"
)


def application(path: str) -> dict:
    return yaml.safe_load((ROOT / path).read_text())


class SubstrateGKEOIDCTests(unittest.TestCase):
    def test_kyverno_admission_invalidates_discovery_for_new_crds(self):
        kyverno = application("argocd/prod/infrastructure/kyverno.yaml")
        values = yaml.safe_load(kyverno["spec"]["source"]["helm"]["values"])

        self.assertTrue(values["admissionController"]["crdWatcher"])

    def test_kagent_metadata_preserves_promotion_and_sync_annotations(self):
        kagent = application("argocd/prod/infrastructure/kagent.yaml")

        self.assertEqual(
            "kargo-infra:platform-tools-prod",
            kagent["metadata"]["annotations"]["kargo.akuity.io/authorized-stage"],
        )
        self.assertEqual(
            "-3", kagent["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"]
        )

    def test_substrate_control_plane_and_crds_include_external_issuer_fix(self):
        control_plane = application("argocd/prod/infrastructure/substrate.yaml")
        crds = application("argocd/prod/infrastructure/substrate-crds.yaml")

        self.assertEqual(
            SUBSTRATE_VERSION, control_plane["spec"]["source"]["targetRevision"]
        )
        self.assertEqual(SUBSTRATE_VERSION, crds["spec"]["source"]["targetRevision"])

        values = yaml.safe_load(control_plane["spec"]["source"]["helm"]["values"])
        self.assertEqual(
            "https://container.googleapis.com/v1/projects/tesseracthub-480811/"
            "locations/asia-south1/clusters/tesseract-prod-in-gke",
            values["auth"]["jwt"]["issuer"],
        )

    def test_upgrade_preserves_existing_tls_and_signing_material(self):
        control_plane = application("argocd/prod/infrastructure/substrate.yaml")

        protected_data = {
            (difference["kind"], difference["name"]): set(difference["jsonPointers"])
            for difference in control_plane["spec"]["ignoreDifferences"]
        }
        self.assertEqual(
            {
                ("ConfigMap", "ateapi-ca"): {"/data"},
                ("Secret", "ateapi-tls"): {"/data"},
                ("Secret", "session-id-ca-pool"): {"/data"},
                ("Secret", "session-id-jwt-pool"): {"/data"},
            },
            protected_data,
        )
        self.assertIn(
            "RespectIgnoreDifferences=true",
            control_plane["spec"]["syncPolicy"]["syncOptions"],
        )

    def test_gvisor_worker_matches_substrate_control_plane(self):
        kagent = application("argocd/prod/infrastructure/kagent.yaml")
        values = yaml.safe_load(kagent["spec"]["source"]["helm"]["values"])

        self.assertEqual(
            "ghcr.io/kagent-dev/substrate/"
            f"ateom-gvisor:v{SUBSTRATE_VERSION}@{SUBSTRATE_WORKER_DIGEST}",
            values["substrateWorkerPool"]["ateomImage"],
        )


if __name__ == "__main__":
    unittest.main()
