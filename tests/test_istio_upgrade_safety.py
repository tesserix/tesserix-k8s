from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
APPS = [
    "istio-base",
    "istio-istiod",
    "istio-cni",
    "istio-ztunnel",
    "istio-egress-gateway",
    "istio-ingress-gateway",
    "istio-ingress-gateway-internal",
    "custom-ingress-gateway",
    "homechef-ingress-gateway",
    "zitadel-ingress-gateway",
]


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node):
    result = {}
    for key, value in node.value:
        key = loader.construct_object(key)
        if key in result:
            raise ValueError(f"Duplicate YAML key: {key}")
        result[key] = loader.construct_object(value)
    return result


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping
)


class IstioUpgradeSafetyTests(unittest.TestCase):
    def test_all_mesh_apps_retain_kargo_authorization_and_explicit_sync_control(self):
        for name in APPS:
            with self.subTest(app=name):
                app = yaml.load(
                    (ROOT / f"argocd/prod/infrastructure/{name}.yaml").read_text(),
                    Loader=UniqueKeyLoader,
                )
                self.assertEqual(
                    app["metadata"]["annotations"]["kargo.akuity.io/authorized-stage"],
                    "kargo-infra:istio-prod",
                )
                self.assertNotIn("automated", app["spec"]["syncPolicy"])
                self.assertNotIn(
                    "Replace=true", app["spec"]["syncPolicy"].get("syncOptions", [])
                )

    def test_sync_waves_put_control_plane_before_ambient_data_plane(self):
        waves = {}
        for name in APPS:
            app = yaml.safe_load(
                (ROOT / f"argocd/prod/infrastructure/{name}.yaml").read_text()
            )
            waves[name] = int(
                app["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"]
            )
        order = ["istio-base", "istio-istiod", "istio-cni", "istio-ztunnel"]
        for first, second in zip(order, order[1:]):
            self.assertLess(waves[first], waves[second])
        for name in APPS[4:]:
            self.assertLess(waves["istio-ztunnel"], waves[name])


if __name__ == "__main__":
    unittest.main()
