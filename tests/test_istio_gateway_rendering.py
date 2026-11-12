from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
GATEWAYS = {
    "istio-egress-gateway": ("istio-egressgateway", "ClusterIP"),
    "istio-ingress-gateway": ("istio-ingressgateway", "ClusterIP"),
    "istio-ingress-gateway-internal": ("istio-ingressgateway-internal", "ClusterIP"),
    "custom-ingress-gateway": ("custom-ingressgateway", "LoadBalancer"),
    "homechef-ingress-gateway": ("homechef-ingressgateway", "ClusterIP"),
    "zitadel-ingress-gateway": ("zitadel-ingressgateway", "ClusterIP"),
}


class IstioGatewayRenderingTests(unittest.TestCase):
    def test_effective_argo_values_preserve_gateway_resources_and_exposure(self):
        for name, (resource_name, service_type) in GATEWAYS.items():
            with self.subTest(gateway=name):
                app = yaml.safe_load(
                    (ROOT / f"argocd/prod/infrastructure/{name}.yaml").read_text()
                )
                source = app["spec"]["source"]
                helm = source["helm"]
                # Argo uses valuesObject instead of its inline values string.
                values = helm.get(
                    "valuesObject", yaml.safe_load(helm.get("values", ""))
                )
                chart = (
                    ROOT / source["path"]
                    if "path" in source
                    else ROOT / "charts/thirdparty/istio-release/gateway-1.31.4.tgz"
                )
                with tempfile.TemporaryDirectory() as temporary:
                    values_file = Path(temporary) / "values.yaml"
                    values_file.write_text(yaml.safe_dump(values))
                    command = [
                        "helm",
                        "template",
                        helm["releaseName"],
                        str(chart),
                        "-n",
                        app["spec"]["destination"]["namespace"],
                        "-f",
                        str(values_file),
                    ]
                    if helm.get("skipSchemaValidation"):
                        command.append("--skip-schema-validation")
                    rendered = subprocess.check_output(command, text=True)
                resources = [doc for doc in yaml.safe_load_all(rendered) if doc]
                deployments = [doc for doc in resources if doc["kind"] == "Deployment"]
                services = [doc for doc in resources if doc["kind"] == "Service"]
                self.assertEqual(
                    [doc["metadata"]["name"] for doc in deployments], [resource_name]
                )
                self.assertEqual(
                    [doc["metadata"]["name"] for doc in services], [resource_name]
                )
                self.assertEqual(services[0]["spec"]["type"], service_type)
                self.assertEqual(
                    services[0]["spec"]["selector"],
                    deployments[0]["spec"]["selector"]["matchLabels"],
                )


if __name__ == "__main__":
    unittest.main()
