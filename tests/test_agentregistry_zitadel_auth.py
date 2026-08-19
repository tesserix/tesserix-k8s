import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
ISSUER = "https://auth.tesserix.app"
PROJECT_ID = "386889024519799084"
ADMIN_EMAILS = {"samyak.rout@gmail.com", "mahesh.sangawar@gmail.com"}


def render_registry():
    result = subprocess.run(
        [
            "helm",
            "template",
            "agentic-registry",
            str(ROOT / "charts/apps/agentic-registry"),
            "--namespace",
            "agentregistry-system",
            "--values",
            str(ROOT / "charts/apps/agentic-registry/values-prod.yaml"),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def render_agentic_istio():
    result = subprocess.run(
        ["kubectl", "kustomize", str(ROOT / "manifests/agentic-istio")],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents, kind, name):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


class AgentRegistryZitadelAuthTests(unittest.TestCase):
    def test_registry_uses_jwks_and_a_hardened_zitadel_proxy(self):
        documents = render_registry()
        config = resource(documents, "ConfigMap", "agentregistry-config")
        registry = resource(documents, "Deployment", "agentregistry")
        name = "agentregistry-ui-oauth2-proxy"
        proxy = resource(documents, "Deployment", name)
        service = resource(documents, "Service", name)
        emails = resource(documents, "ConfigMap", f"{name}-emails")
        external_secret = resource(documents, "ExternalSecret", name)
        pdb = resource(documents, "PodDisruptionBudget", name)
        network_policy = resource(documents, "NetworkPolicy", name)

        self.assertEqual("jwks", config["data"]["AUTH_MODE"])
        self.assertEqual(f"{ISSUER}/oauth/v2/keys", config["data"]["AUTH_JWKS_URL"])
        self.assertEqual(ISSUER, config["data"]["AUTH_ISSUER"])
        self.assertEqual(
            f"urn:zitadel:iam:org:project:{PROJECT_ID}:roles",
            config["data"]["AUTH_GROUPS_CLAIM"],
        )
        self.assertEqual("agentgateway.models", config["data"]["AUTH_ADMIN_ROLE"])
        self.assertEqual(PROJECT_ID, config["data"]["AUTH_AUDIENCE"])
        self.assertEqual(
            "samyak.rout@gmail.com,mahesh.sangawar@gmail.com",
            config["data"]["AUTH_ADMIN_EMAILS"],
        )

        registry_env = {
            item["name"]: item
            for item in registry["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertNotIn("AUTH_AUDIENCE", registry_env)

        self.assertEqual(2, proxy["spec"]["replicas"])
        self.assertEqual(1, pdb["spec"]["minAvailable"])
        self.assertEqual("ClusterIP", service["spec"]["type"])
        self.assertEqual(4180, service["spec"]["ports"][0]["port"])
        container = proxy["spec"]["template"]["spec"]["containers"][0]
        self.assertIn("@sha256:", container["image"])
        self.assertIn(f"--oidc-issuer-url={ISSUER}", container["args"])
        self.assertIn(
            "--redirect-url=https://aregistry.tesserix.app/oauth2/callback",
            container["args"],
        )
        self.assertIn(
            "--upstream=http://agentregistry.agentregistry-system.svc.cluster.local:12121",
            container["args"],
        )
        self.assertIn("--pass-access-token=true", container["args"])
        self.assertIn("--pass-authorization-header=false", container["args"])
        self.assertIn("--cookie-secure=true", container["args"])
        self.assertIn("--cookie-httponly=true", container["args"])
        self.assertIn("--cookie-samesite=lax", container["args"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(
            ADMIN_EMAILS,
            set(emails["data"]["authenticated-emails.txt"].splitlines()),
        )
        self.assertEqual(
            {
                "prod-agentregistry-ui-client-id",
                "prod-agentregistry-ui-client-secret",
                "prod-agentregistry-ui-cookie-secret",
            },
            {
                item["remoteRef"]["key"]
                for item in external_secret["spec"]["data"]
            },
        )
        self.assertEqual(["Ingress", "Egress"], network_policy["spec"]["policyTypes"])

    def test_browser_and_machine_routes_have_separate_auth_boundaries(self):
        documents = render_agentic_istio()
        virtual_service = resource(documents, "VirtualService", "aregistry-ui")
        apply_route = virtual_service["spec"]["http"][0]
        browser_route = virtual_service["spec"]["http"][-1]

        self.assertEqual(
            {"exact": "/v0/apply"}, apply_route["match"][0]["uri"]
        )
        self.assertEqual("POST", apply_route["match"][0]["method"]["exact"])
        self.assertEqual(
            "agentregistry.agentregistry-system.svc.cluster.local",
            apply_route["route"][0]["destination"]["host"],
        )
        self.assertEqual(
            "agentregistry-ui-oauth2-proxy.agentregistry-system.svc.cluster.local",
            browser_route["route"][0]["destination"]["host"],
        )
        self.assertEqual(4180, browser_route["route"][0]["destination"]["port"]["number"])

        allow = resource(documents, "AuthorizationPolicy", "agentregistry-authz")
        proxy_principal = (
            "cluster.local/ns/agentregistry-system/sa/agentregistry-ui-oauth2-proxy"
        )
        agentgateway_proxy_principal = (
            "cluster.local/ns/agentgateway-system/sa/agentgateway-admin-ui-oauth2-proxy"
        )
        route_sync_principal = (
            "cluster.local/ns/agentgateway-system/sa/agentgateway-route-sync"
        )
        ingress_principal = (
            "cluster.local/ns/istio-ingress/sa/istio-ingressgateway"
        )
        self.assertTrue(
            any(
                rule.get("from", [{}])[0].get("source", {}).get("principals")
                == [ingress_principal]
                and rule.get("to", [{}])[0].get("operation", {}).get("ports")
                == ["4180"]
                for rule in allow["spec"]["rules"]
            )
        )
        self.assertTrue(
            any(
                rule.get("from", [{}])[0].get("source", {}).get("principals")
                == [proxy_principal]
                and rule.get("to", [{}])[0].get("operation", {}).get("ports")
                == ["12121"]
                for rule in allow["spec"]["rules"]
            )
        )
        agentgateway_rule = next(
            rule
            for rule in allow["spec"]["rules"]
            if rule.get("from", [{}])[0].get("source", {}).get("principals")
            == [agentgateway_proxy_principal]
        )
        self.assertIn(
            {"methods": ["PUT", "DELETE"], "paths": ["/v0/agentgateway/*"]},
            [target["operation"] for target in agentgateway_rule["to"]],
        )
        route_sync_rule = next(
            rule
            for rule in allow["spec"]["rules"]
            if rule.get("from", [{}])[0].get("source", {}).get("principals")
            == [route_sync_principal]
        )
        self.assertIn(
            {"methods": ["POST"], "paths": ["/v0/agentgateway/import"]},
            [target["operation"] for target in route_sync_rule["to"]],
        )

        deny = resource(
            documents,
            "AuthorizationPolicy",
            "agentregistry-deny-writes-from-non-bootstrap",
        )
        allowed_writers = deny["spec"]["rules"][0]["from"][0]["source"][
            "notPrincipals"
        ]
        self.assertIn(proxy_principal, allowed_writers)
        self.assertIn(agentgateway_proxy_principal, allowed_writers)
        self.assertIn(route_sync_principal, allowed_writers)
        self.assertNotIn("cluster.local/ns/devai/sa/devai-auth-bff", allowed_writers)
        self.assertIn("cluster.local/ns/devai/sa/devai-registry-bootstrap", allowed_writers)
        self.assertIn("cluster.local/ns/devai/sa/devai-api", allowed_writers)
        route_sync_deny = next(
            rule
            for rule in deny["spec"]["rules"]
            if rule.get("from", [{}])[0].get("source", {}).get("principals")
            == [route_sync_principal]
        )
        self.assertIn(
            {"methods": ["POST"], "notPaths": ["/v0/agentgateway/import"]},
            [target["operation"] for target in route_sync_deny["to"]],
        )

        ingress_app = yaml.safe_load(
            (ROOT / "argocd/prod/infrastructure/istio-auth-policies.yaml").read_text()
        )
        ingress_values = yaml.safe_load(
            ingress_app["spec"]["source"]["helm"]["values"]
        )
        registry_frontend = next(
            item
            for item in ingress_values["frontendApps"]
            if item["name"] == "aregistry-ui"
        )
        self.assertEqual("agentregistry-ui-oauth2-proxy", registry_frontend["label"])


if __name__ == "__main__":
    unittest.main()
