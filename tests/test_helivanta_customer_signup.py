import pathlib
import subprocess
import unittest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


def render(chart, release, namespace, *args):
    output = subprocess.check_output(["helm", "template", release, str(ROOT / "charts/apps" / chart), "--namespace", namespace, *args], text=True)
    return [doc for doc in yaml.safe_load_all(output) if doc]


class CustomerSignup(unittest.TestCase):
    def test_only_platform_api_gets_customer_provisioning_audience(self):
        docs = render("helivanta-api", "helivanta-api", "helivanta")
        api = next(doc for doc in docs if doc["kind"] == "Deployment" and doc["metadata"]["name"] == "helivanta-api")
        spec = api["spec"]["template"]["spec"]
        volume = next((v for v in spec["volumes"] if v["name"] == "customer-onboarding"), None)
        self.assertIsNotNone(volume, "Public signup needs its separate workload audience, never a shared identity token")
        self.assertEqual(volume["projected"]["sources"], [{"serviceAccountToken": {"audience": "helivanta-customer-onboarding", "expirationSeconds": 600, "path": "token"}}])
        mounts = spec["containers"][0]["volumeMounts"]
        self.assertIn({"name": "customer-onboarding", "mountPath": "/var/run/customer-onboarding", "readOnly": True}, mounts)
        for doc in docs:
            if doc["kind"] != "Deployment" or doc["metadata"]["name"] == "helivanta-api":
                continue
            self.assertFalse(any(v["name"] == "customer-onboarding" for v in doc["spec"]["template"]["spec"].get("volumes", [])))

    def test_owner_security_has_separate_workload_and_metadata_patch_permission(self):
        docs = render("helivanta-api", "helivanta-api", "helivanta")
        api = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "helivanta-api")
        spec = api["spec"]["template"]["spec"]
        volume = next(v for v in spec["volumes"] if v["name"] == "owner-security")
        self.assertEqual(volume["projected"]["sources"], [{"serviceAccountToken": {"audience": "helivanta-owner-security", "expirationSeconds": 600, "path": "token"}}])
        self.assertIn({"name": "owner-security", "mountPath": "/var/run/owner-security", "readOnly": True}, spec["containers"][0]["volumeMounts"])
        docs = render("onboarding-service", "onboarding-service", "onboarding", "-f", str(ROOT / "charts/apps/onboarding-service/values-prod.yaml"))
        role = next(d for d in docs if d["kind"] == "Role" and d["metadata"]["name"] == "onboarding-hospital-claims")
        self.assertEqual(role["rules"][0]["verbs"], ["create", "get", "patch"])
        self.assertNotIn("delete", role["rules"][0]["verbs"])

    def test_customer_setup_uses_an_exact_global_route(self):
        docs = render("helivanta-istio", "helivanta-istio", "helivanta")
        service = next(doc for doc in docs if doc["kind"] == "VirtualService")
        route = next((r for r in service["spec"]["http"] if r.get("match") == [{"uri": {"exact": "/api/internal/v1/customer-workspaces"}}]), None)
        self.assertIsNotNone(route, "Workload setup must reach the Global API without a browser session")
        self.assertEqual(route["rewrite"]["uri"], "/internal/v1/customer-workspaces")
        self.assertEqual(route["route"][0]["destination"]["host"], "helivanta-global-api.helivanta.svc.cluster.local")
        self.assertFalse(any(m.get("uri", {}).get("prefix", "").startswith("/api/internal") for r in service["spec"]["http"] for m in r.get("match", [])))

    def test_private_signup_has_explicit_namespace_scoped_network_paths(self):
        incoming = render("onboarding-service", "onboarding-service", "onboarding", "-f", str(ROOT / "charts/apps/onboarding-service/values-prod.yaml"))
        policy = next((d for d in incoming if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "allow-helivanta-customer-signup"), None)
        self.assertIsNotNone(policy, "The private receiver must admit the verified platform workload")
        source = policy["spec"]["ingress"][0]["from"][0]
        self.assertEqual(source["namespaceSelector"]["matchLabels"], {"kubernetes.io/metadata.name": "helivanta"})
        self.assertEqual(source["podSelector"]["matchLabels"]["app.kubernetes.io/name"], "helivanta-api")
        outgoing = render("helivanta-api", "helivanta-api", "helivanta")
        policy = next((d for d in outgoing if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "helivanta-api-customer-signup"), None)
        self.assertIsNotNone(policy, "The platform must reach only the onboarding owner's pods for signup")
        destination = policy["spec"]["egress"][0]["to"][0]
        self.assertEqual(destination["namespaceSelector"]["matchLabels"], {"kubernetes.io/metadata.name": "onboarding"})
        self.assertEqual(destination["podSelector"]["matchLabels"]["app.kubernetes.io/name"], "onboarding-api")
