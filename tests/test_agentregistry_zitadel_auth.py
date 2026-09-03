import json
import pathlib
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
ISSUER = "https://auth.tesserix.app"
PROJECT_ID = "386930054896026901"
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


def render_zitadel_bootstrap():
    result = subprocess.run(
        [
            "helm",
            "template",
            "zitadel-bootstrap",
            str(ROOT / "charts/apps/zitadel-bootstrap"),
            "--namespace",
            "zitadel",
        ],
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
        self.assertEqual("agentregistry.admin", config["data"]["AUTH_ADMIN_ROLE"])
        self.assertEqual(PROJECT_ID, config["data"]["AUTH_AUDIENCE"])
        self.assertEqual(
            "urn:zitadel:iam:org:id",
            config["data"]["AUTH_TENANT_CLAIM"],
        )
        self.assertEqual(
            "http://onboarding-api.onboarding.svc.cluster.local:8080",
            config["data"]["IDENTITY_CONTROL_PLANE_URL"],
        )
        self.assertEqual(
            "samyak.rout@gmail.com,mahesh.sangawar@gmail.com",
            config["data"]["AUTH_ADMIN_EMAILS"],
        )

        registry_env = {
            item["name"]: item
            for item in registry["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        self.assertNotIn("AUTH_AUDIENCE", registry_env)
        self.assertEqual(
            {"name": "agentregistry-secrets", "key": "AUTH_CLI_CLIENT_ID"},
            registry_env["AUTH_CLI_CLIENT_ID"]["valueFrom"]["secretKeyRef"],
        )

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
        self.assertIn("--pass-authorization-header=true", container["args"])
        scope = next(arg for arg in container["args"] if arg.startswith("--scope="))
        self.assertIn("urn:zitadel:iam:user:metadata", scope)
        self.assertIn(
            "--backend-logout-url=https://auth.tesserix.app/oidc/v1/end_session?id_token_hint={id_token}",
            container["args"],
        )
        self.assertIn("--cookie-secure=true", container["args"])
        self.assertIn("--cookie-httponly=true", container["args"])
        self.assertIn("--cookie-samesite=lax", container["args"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(set(), set(emails["data"]["authenticated-emails.txt"].splitlines()))
        self.assertIn("--email-domain=*", container["args"])
        self.assertNotIn(
            "--authenticated-emails-file=/etc/oauth2-proxy/authenticated-emails.txt",
            container["args"],
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

        registry_secret = resource(documents, "ExternalSecret", "agentregistry-secrets")
        self.assertIn(
            {
                "secretKey": "AUTH_CLI_CLIENT_ID",
                "remoteRef": {"key": "prod-agentregistry-cli-client-id"},
            },
            registry_secret["spec"]["data"],
        )
        self.assertEqual(["Ingress", "Egress"], network_policy["spec"]["policyTypes"])

    def test_registry_oidc_application_uses_login_v2(self):
        documents = render_zitadel_bootstrap()
        config = resource(
            documents, "ConfigMap", "zitadel-bootstrap-config"
        )
        desired = json.loads(config["data"]["desired.json"])
        project = next(
            item
            for item in desired["platformProjects"]
            if item["name"] == "AgentRegistry"
        )

        self.assertEqual("TESSERIX", project["org"])
        self.assertEqual("386930054896026901", project["expectedId"])
        self.assertEqual(
            {
                "name": "agentregistry-ui",
                "appType": "OIDC_APP_TYPE_WEB",
                "authMethodType": "OIDC_AUTH_METHOD_TYPE_BASIC",
                "loginBaseUri": "https://auth.tesserix.app/ui/v2/login",
                "redirectUris": [
                    "https://aregistry.tesserix.app/oauth2/callback"
                ],
                "postLogoutRedirectUris": [
                    "https://aregistry.tesserix.app/"
                ],
            },
            project["oidcApps"][0],
        )

        self.assertEqual(
            {
                "name": "agentregistry-cli",
                "appType": "OIDC_APP_TYPE_NATIVE",
                "authMethodType": "OIDC_AUTH_METHOD_TYPE_NONE",
                "grantTypes": [
                    "OIDC_GRANT_TYPE_AUTHORIZATION_CODE",
                    "OIDC_GRANT_TYPE_REFRESH_TOKEN",
                    "OIDC_GRANT_TYPE_DEVICE_CODE",
                ],
                "redirectUris": ["http://127.0.0.1/callback"],
                "postLogoutRedirectUris": [],
            },
            project["oidcApps"][1],
        )

    def test_tesserix_is_the_default_organization(self):
        documents = render_zitadel_bootstrap()
        config = resource(documents, "ConfigMap", "zitadel-bootstrap-config")
        desired = json.loads(config["data"]["desired.json"])

        self.assertEqual("TESSERIX", desired["defaultOrg"])

    def test_registry_admin_access_is_reconciled(self):
        documents = render_zitadel_bootstrap()
        config = resource(documents, "ConfigMap", "zitadel-bootstrap-config")
        desired = json.loads(config["data"]["desired.json"])
        project = next(
            item
            for item in desired["platformProjects"]
            if item["name"] == "AgentRegistry"
        )

        self.assertEqual(
            {
                "agentregistry.admin",
                "registry.reader",
                "registry.publisher",
                "registry.deleter",
            },
            {role["key"] for role in project["roles"]},
        )
        self.assertEqual(
            [
                {
                    "login": "samyak.rout@gmail.com",
                    "roles": [
                        "agentregistry.admin",
                        "registry.reader",
                        "registry.publisher",
                        "registry.deleter",
                    ],
                },
                {
                    "login": "mahesh.sangawar@gmail.com",
                    "roles": [
                        "agentregistry.admin",
                        "registry.reader",
                        "registry.publisher",
                        "registry.deleter",
                    ],
                },
            ],
            project["humanGrants"],
        )

    def test_platform_admins_receive_every_declared_project_role(self):
        documents = render_zitadel_bootstrap()
        config = resource(documents, "ConfigMap", "zitadel-bootstrap-config")
        desired = json.loads(config["data"]["desired.json"])
        platform_admins = {
            "samyak.rout@gmail.com",
            "mahesh.sangawar@gmail.com",
        }

        self.assertTrue(platform_admins.issubset(desired["admins"]))
        for project in desired["platformProjects"]:
            # Product projects are exempt: their roles describe merchants and
            # storefront customers, not operators. `mark8ly.staff` on an
            # operator would be a real access change to a closed merchant
            # surface (that project sets projectRoleCheck: true, and its own
            # comment calls the role "what keeps storefront customers out"),
            # and `mark8ly.customer` would make them a shopper.
            #
            # The default is `platform`, so an entry that forgets to say what
            # it is lands back under this invariant and fails here rather than
            # silently escaping it.
            kind = project.get("kind", "platform")
            self.assertIn(
                kind,
                ("platform", "product"),
                f"{project['name']} declares an unknown kind {kind!r}",
            )
            if kind == "product":
                self.assertNotIn(
                    "humanGrants",
                    project,
                    f"{project['name']} is a product project but grants humans "
                    "roles directly — say why, or make it kind: platform",
                )
                continue

            declared_roles = {role["key"] for role in project.get("roles", [])}
            grants = {
                grant["login"]: set(grant["roles"])
                for grant in project.get("humanGrants", [])
            }
            for login in platform_admins:
                self.assertEqual(
                    declared_roles,
                    grants.get(login),
                    f"{login} must have full access to {project['name']}",
                )

    def test_no_product_project_is_left_in_the_reserved_org(self):
        documents = render_zitadel_bootstrap()
        config = resource(documents, "ConfigMap", "zitadel-bootstrap-config")
        desired = json.loads(config["data"]["desired.json"])

        # ZITADEL keeps only its own console project; every product project —
        # AgentGateway included — belongs in TESSERIX.
        self.assertEqual(["ZITADEL"], desired["reservedOrg"]["allowedProjects"])
        self.assertEqual(
            set(),
            {
                item["name"]
                for item in desired["platformProjects"]
                if item["org"] == "ZITADEL"
            },
        )

        gateway = next(
            item
            for item in desired["platformProjects"]
            if item["name"] == "AgentGateway"
        )
        self.assertEqual("TESSERIX", gateway["org"])
        self.assertEqual("387190457387450503", gateway["expectedId"])

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
        self.assertIn(ingress_principal, allowed_writers)
        self.assertNotIn("cluster.local/ns/devai/sa/devai-auth-bff", allowed_writers)
        self.assertIn("cluster.local/ns/devai/sa/devai-registry-bootstrap", allowed_writers)
        self.assertIn("cluster.local/ns/devai/sa/devai-api", allowed_writers)
        ingress_deny = next(
            rule
            for rule in deny["spec"]["rules"]
            if rule.get("from", [{}])[0].get("source", {}).get("principals")
            == [ingress_principal]
        )
        self.assertIn(
            {"methods": ["POST"], "notPaths": ["/v0/apply"]},
            [target["operation"] for target in ingress_deny["to"]],
        )
        self.assertIn(
            {"methods": ["PUT", "PATCH", "DELETE"]},
            [target["operation"] for target in ingress_deny["to"]],
        )
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

    def test_public_discovery_bypasses_the_human_session_proxy(self):
        documents = render_agentic_istio()
        virtual_service = resource(documents, "VirtualService", "aregistry-ui")
        public_route = virtual_service["spec"]["http"][1]

        self.assertEqual(
            "agentregistry.agentregistry-system.svc.cluster.local",
            public_route["route"][0]["destination"]["host"],
        )
        self.assertEqual(12121, public_route["route"][0]["destination"]["port"]["number"])
        matches = public_route["match"]
        exact_paths = {
            match["uri"]["exact"]
            for match in matches
            if "exact" in match["uri"]
        }
        regex_paths = {
            match["uri"]["regex"]
            for match in matches
            if "regex" in match["uri"]
        }
        self.assertEqual(
            {"/healthz", "/v0/health", "/v0/signing-key", "/v0/auth/config"},
            exact_paths,
        )
        self.assertEqual(
            {
                r"^/v0/agents/[^/]+/(card|\.well-known/agent-card\.json)$",
                r"^/v0/agents/[^/]+/[^/]+/card$",
            },
            regex_paths,
        )
        self.assertTrue(all(match["method"]["exact"] == "GET" for match in matches))

        allow = resource(documents, "AuthorizationPolicy", "agentregistry-authz")
        ingress_principal = (
            "cluster.local/ns/istio-ingress/sa/istio-ingressgateway"
        )
        public_paths = {
            "/healthz",
            "/v0/health",
            "/v0/signing-key",
            "/v0/auth/config",
            "/v0/agents/{*}/card",
            "/v0/agents/{*}/.well-known/agent-card.json",
            "/v0/agents/{*}/{*}/card",
        }
        self.assertTrue(
            any(
                rule.get("from", [{}])[0].get("source", {}).get("principals")
                == [ingress_principal]
                and rule.get("to", [{}])[0].get("operation", {}).get("methods")
                == ["GET"]
                and set(rule["to"][0]["operation"]["paths"]) == public_paths
                for rule in allow["spec"]["rules"]
            )
        )

    def test_bearer_registry_api_bypasses_the_human_session_proxy(self):
        documents = render_agentic_istio()
        virtual_service = resource(documents, "VirtualService", "aregistry-ui")
        bearer_route = next(
            route
            for route in virtual_service["spec"]["http"]
            if any(
                match.get("headers", {}).get("authorization")
                == {"regex": r"^Bearer .+"}
                for match in route.get("match", [])
            )
        )

        self.assertEqual({"prefix": "/v0/"}, bearer_route["match"][0]["uri"])
        self.assertEqual(
            "agentregistry.agentregistry-system.svc.cluster.local",
            bearer_route["route"][0]["destination"]["host"],
        )
        self.assertEqual(
            12121, bearer_route["route"][0]["destination"]["port"]["number"]
        )

        allow = resource(documents, "AuthorizationPolicy", "agentregistry-authz")
        ingress_principal = (
            "cluster.local/ns/istio-ingress/sa/istio-ingressgateway"
        )
        self.assertTrue(
            any(
                rule.get("from", [{}])[0].get("source", {}).get("principals")
                == [ingress_principal]
                and rule.get("to")
                == [{"operation": {"methods": ["GET"], "paths": ["/v0/*"]}}]
                and rule.get("when")
                == [
                    {
                        "key": "request.headers[authorization]",
                        "values": ["Bearer *"],
                    }
                ]
                for rule in allow["spec"]["rules"]
            )
        )


if __name__ == "__main__":
    unittest.main()
