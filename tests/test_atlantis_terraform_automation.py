import fnmatch
import json
import os
import pathlib
import posixpath
import re
import subprocess
import tempfile
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]
TERRAFORM_ROOT = ROOT / "terraform-new"
ATLANTIS_FAILURE_PROJECT = "atlantis-failure-smoke"
STATE_BUCKET = "tesseract-terraform-states"
LIVE_STATE_PREFIXES = {
    "stacks/prod/foundation",
    "stacks/prod/network",
    "stacks/prod/storage",
    "stacks/prod/gke",
    "stacks/prod/k8s-bootstrap",
    "stacks/prod/workload-identity",
    "stacks/prod/app-secrets",
    "stacks/prod/communication-services",
    "stacks/prod/github-arc",
    "stacks/prod/identity-platform",
    "stacks/prod/vertex",
    "stacks/prod/cloud-run",
    "state/devtest",
    "state/prod",
    "terraform/devtest",
    "terraform/state",
    "tesserix-governance",
}


def load_yaml(path):
    return yaml.safe_load(path.read_text())


def render_atlantis_chart():
    result = subprocess.run(
        [
            "helm",
            "template",
            "atlantis",
            str(ROOT / "charts/thirdparty/atlantis"),
            "--namespace",
            "atlantis",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def render_istio_auth_policies():
    """Render the way ArgoCD does: the Application's inline block wins over values-prod."""
    application = load_yaml(ROOT / "argocd/prod/infrastructure/istio-auth-policies.yaml")
    chart = ROOT / "charts/infrastructure/istio-auth-policies"
    result = subprocess.run(
        [
            "helm",
            "template",
            "istio-auth-policies",
            str(chart),
            "--namespace",
            "istio-ingress",
            "--values",
            str(chart / "values.yaml"),
            "--values",
            str(chart / "values-prod.yaml"),
            "--values",
            "-",
        ],
        input=application["spec"]["source"]["helm"]["values"],
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


class TerraformGraphTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.graph = load_yaml(TERRAFORM_ROOT / "dependencies.yaml")

    def test_graph_is_canonical_complete_and_acyclic(self):
        stacks = self.graph["stacks"]
        stack_dirs = {
            path.name
            for path in (TERRAFORM_ROOT / "stacks").iterdir()
            if path.is_dir()
        }
        self.assertEqual(stack_dirs, set(stacks))

        flattened_order = [
            stack
            for phase in self.graph["execution_order"]
            for stack in phase["stacks"]
        ]
        self.assertEqual(set(stacks), set(flattened_order))
        self.assertEqual(len(stacks), len(flattened_order))

        positions = {stack: index for index, stack in enumerate(flattened_order)}
        for stack, config in stacks.items():
            self.assertEqual(stack, pathlib.Path(config["path"]).name)
            for dependency in config["dependencies"]:
                self.assertIn(dependency, stacks)
                self.assertLess(positions[dependency], positions[stack])

    def test_all_observed_state_is_owned_or_acknowledged(self):
        state = self.graph["state"]
        managed = {stack["state_prefix"] for stack in self.graph["stacks"].values()}
        orphans = {
            config["state_prefix"]
            for config in state["acknowledged_orphans"].values()
        }
        self.assertEqual(
            LIVE_STATE_PREFIXES | {"stacks/prod/state-bootstrap"},
            managed | orphans,
        )
        for config in state["acknowledged_orphans"].values():
            self.assertFalse(config["managed"])

    def test_each_backend_uses_the_canonical_bucket_and_prefix(self):
        for stack_name, config in self.graph["stacks"].items():
            backend = (TERRAFORM_ROOT / config["path"] / "backend.tf").read_text()
            self.assertRegex(backend, rf'bucket\s*=\s*"{STATE_BUCKET}"')
            self.assertRegex(
                backend,
                rf'prefix\s*=\s*"{re.escape(config["state_prefix"])}"',
                stack_name,
            )

    def test_remote_state_references_only_canonical_prefixes(self):
        managed = {stack["state_prefix"] for stack in self.graph["stacks"].values()}
        remote_state_pattern = re.compile(
            r'^data\s+"terraform_remote_state"\s+"[^"]+"\s*\{.*?^\}',
            re.MULTILINE | re.DOTALL,
        )
        prefix_pattern = re.compile(r'^\s*prefix\s*=\s*"([^"]+)"', re.MULTILINE)
        for terraform_file in (TERRAFORM_ROOT / "stacks").glob("*/*.tf"):
            for remote_state in remote_state_pattern.findall(terraform_file.read_text()):
                prefixes = prefix_pattern.findall(remote_state)
                self.assertEqual(len(prefixes), 1, terraform_file)
                prefix = prefixes[0]
                self.assertIn(prefix, managed, terraform_file)

    def test_every_stack_commits_a_provider_lock(self):
        for config in self.graph["stacks"].values():
            self.assertTrue(
                (TERRAFORM_ROOT / config["path"] / ".terraform.lock.hcl").is_file(),
                config["path"],
            )

    def test_state_bootstrap_is_protected_and_versioned(self):
        main = (TERRAFORM_ROOT / "stacks/00-state-bootstrap/main.tf").read_text()
        self.assertRegex(main, r"force_destroy\s*=\s*false")
        self.assertIn("prevent_destroy = true", main)
        self.assertRegex(main, r"versioning\s*\{\s*enabled\s*=\s*true")
        self.assertIn('public_access_prevention    = "enforced"', main)
        self.assertIn("uniform_bucket_level_access = true", main)


class AtlantisRepositoryConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.graph = load_yaml(TERRAFORM_ROOT / "dependencies.yaml")
        cls.atlantis = load_yaml(ROOT / "atlantis.yaml")
        cls.values = load_yaml(ROOT / "charts/thirdparty/atlantis/values.yaml")

    def matching_projects(self, changed_path):
        matches = set()
        for project in self.atlantis["projects"]:
            for pattern in project["autoplan"]["when_modified"]:
                repository_pattern = posixpath.normpath(
                    posixpath.join(project["dir"], pattern)
                )
                if fnmatch.fnmatchcase(changed_path, repository_pattern):
                    matches.add(project["name"])
        return matches

    def test_projects_exactly_mirror_the_stack_graph(self):
        graph_stacks = self.graph["stacks"]
        projects = {project["name"]: project for project in self.atlantis["projects"]}
        self.assertEqual(set(graph_stacks) | {ATLANTIS_FAILURE_PROJECT}, set(projects))

        stack_group = {
            stack: phase["phase"]
            for phase in self.graph["execution_order"]
            for stack in phase["stacks"]
        }
        for stack, config in graph_stacks.items():
            project = projects[stack]
            self.assertEqual(f"terraform-new/{config['path']}", project["dir"])
            self.assertEqual(config["dependencies"], project.get("depends_on", []))
            self.assertEqual(stack_group[stack], project["execution_order_group"])
            self.assertTrue(project["autoplan"]["enabled"])

    def test_stack_local_changes_only_autoplan_the_matching_project(self):
        for stack, config in self.graph["stacks"].items():
            changed_path = f"terraform-new/{config['path']}/main.tf"
            self.assertEqual({stack}, self.matching_projects(changed_path))

    def test_shared_paths_autoplan_only_their_intended_projects(self):
        self.assertEqual(
            set(self.graph["stacks"]),
            self.matching_projects("terraform-new/environments/prod/terraform.tfvars"),
        )
        self.assertEqual(
            {"06-workload-identity"},
            self.matching_projects("terraform-new/modules/naming/main.tf"),
        )
        self.assertEqual(
            {"09-github-arc"},
            self.matching_projects(
                "terraform-new/stacks/09-github-arc/runner-values.yaml.tftpl"
            ),
        )
        self.assertEqual(
            set(),
            self.matching_projects("terraform-new/docs/ATLANTIS_RUNBOOK.md"),
        )

    def test_failure_smoke_project_is_manual_and_isolated(self):
        projects = {project["name"]: project for project in self.atlantis["projects"]}
        project = projects[ATLANTIS_FAILURE_PROJECT]

        self.assertEqual("terraform-new/tests/atlantis-failure", project["dir"])
        self.assertEqual(
            {"when_modified": ["*.tf"], "enabled": False}, project["autoplan"]
        )
        self.assertNotIn("depends_on", project)
        self.assertNotIn("execution_order_group", project)

    def test_failure_smoke_stack_returns_an_intentional_plan_error(self):
        fixture = TERRAFORM_ROOT / "tests/atlantis-failure"
        self.assertTrue(fixture.is_dir())

        with tempfile.TemporaryDirectory() as data_dir:
            result = subprocess.run(
                [
                    "terraform",
                    f"-chdir={fixture}",
                    "plan",
                    "-input=false",
                    "-no-color",
                    "-var-file=../../environments/prod/terraform.tfvars",
                ],
                check=False,
                capture_output=True,
                text=True,
                env={**os.environ, "TF_DATA_DIR": data_dir},
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Intentional Atlantis failure smoke test", result.stderr)

    def test_runbook_documents_stack_scoped_commands_and_unlock_scope(self):
        runbook = (TERRAFORM_ROOT / "docs/ATLANTIS_RUNBOOK.md").read_text()
        for command in (
            "atlantis plan -p 12-vertex",
            "atlantis apply -p 12-vertex",
            "atlantis plan",
            "atlantis apply",
            "atlantis unlock",
        ):
            self.assertIn(command, runbook)
        self.assertIn("project-specific unlock", runbook)
        self.assertNotIn("atlantis unlock -p", runbook)

    def test_runbook_documents_pull_request_status_and_comment_feedback(self):
        runbook = (TERRAFORM_ROOT / "docs/ATLANTIS_RUNBOOK.md").read_text()
        self.assertIn("- Commit statuses: read and write", runbook)
        for feedback in (
            "`atlantis/plan: <project>`",
            "`atlantis/plan`",
            "`atlantis/apply: <project>`",
            "required `atlantis/apply`",
            "plan diff",
            "project-specific lock link",
        ):
            self.assertIn(feedback, runbook)

    def test_runbook_documents_the_manual_failure_smoke_test(self):
        runbook = (TERRAFORM_ROOT / "docs/ATLANTIS_RUNBOOK.md").read_text()
        for instruction in (
            "atlantis plan -p atlantis-failure-smoke",
            "`atlantis/plan: atlantis-failure-smoke`",
            "Intentional Atlantis failure smoke test",
            "never apply",
        ):
            self.assertIn(instruction, runbook)

    def test_repository_cannot_override_the_trusted_workflow(self):
        self.assertNotIn("workflows", self.atlantis)
        self.assertTrue(self.atlantis["automerge"])
        self.assertTrue(self.atlantis["abort_on_execution_order_fail"])

        repo_config = yaml.safe_load(self.values["atlantis"]["repoConfig"])
        repository = repo_config["repos"][0]
        self.assertEqual(
            {"approved", "mergeable", "undiverged"},
            set(repository["apply_requirements"]),
        )
        self.assertEqual(
            {"approved", "mergeable", "undiverged"},
            set(repository["import_requirements"]),
        )
        self.assertEqual([], repository["allowed_overrides"])
        self.assertFalse(repository["allow_custom_workflows"])
        self.assertFalse(self.values["atlantis"]["allowForkPRs"])
        self.assertFalse(self.values["atlantis"]["allowDraftPRs"])

    def test_server_workflow_uses_production_variables_and_saved_plan(self):
        repo_config = yaml.safe_load(self.values["atlantis"]["repoConfig"])
        workflow = repo_config["workflows"]["terraform"]
        self.assertEqual(
            [
                "init",
                {
                    "plan": {
                        "extra_args": [
                            "-var-file=../../environments/prod/terraform.tfvars"
                        ]
                    }
                },
            ],
            workflow["plan"]["steps"],
        )
        self.assertEqual(["apply"], workflow["apply"]["steps"])


class AtlantisPlatformTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.documents = render_atlantis_chart()

    def test_container_environment_names_are_unique(self):
        stateful_set = resource(self.documents, "StatefulSet", "atlantis")
        environment = stateful_set["spec"]["template"]["spec"]["containers"][0][
            "env"
        ]
        names = [entry["name"] for entry in environment]
        self.assertEqual(len(names), len(set(names)))

    def test_workload_identity_uses_a_dedicated_gsa_and_ksa(self):
        service_account = resource(self.documents, "ServiceAccount", "atlantis")
        self.assertEqual(
            "tesseract-prod-atlantis@tesseracthub-480811.iam.gserviceaccount.com",
            service_account["metadata"]["annotations"][
                "iam.gke.io/gcp-service-account"
            ],
        )

        terraform = (
            TERRAFORM_ROOT / "stacks/06-workload-identity/atlantis.tf"
        ).read_text()
        self.assertIn('module "atlantis_name"', terraform)
        self.assertIn("roles/iam.workloadIdentityUser", terraform)
        self.assertIn("${var.project_id}.svc.id.goog[atlantis/atlantis]", terraform)
        for required_role in (
            "roles/artifactregistry.admin",
            "roles/dns.admin",
            "roles/iam.roleAdmin",
            "roles/identityplatform.admin",
        ):
            self.assertIn(required_role, terraform)

    def test_external_secrets_supply_vcs_auth_ui_auth_and_tf_variables(self):
        vcs = resource(self.documents, "ExternalSecret", "atlantis-vcs")
        basic_auth = resource(self.documents, "ExternalSecret", "atlantis-basic-auth")
        tf_vars = resource(self.documents, "ExternalSecret", "atlantis-terraform-vars")

        self.assertEqual(
            {"github_app_id", "github_app_installation_id", "key.pem", "github_secret"},
            {entry["secretKey"] for entry in vcs["spec"]["data"]},
        )
        self.assertEqual(
            {"username", "password"},
            {entry["secretKey"] for entry in basic_auth["spec"]["data"]},
        )
        self.assertEqual(
            {
                "TF_VAR_cloudflare_api_token",
                "TF_VAR_letsencrypt_email",
                "TF_VAR_google_oauth_client_secret",
                "TF_VAR_github_app_id",
                "TF_VAR_github_app_installation_id",
                "TF_VAR_github_app_private_key",
            },
            {entry["secretKey"] for entry in tf_vars["spec"]["data"]},
        )

    def test_external_secrets_use_the_production_crd_version(self):
        external_secrets = [
            document
            for document in self.documents
            if document.get("kind") == "ExternalSecret"
        ]

        # vcs, basic-auth (retained for rollback), terraform vars, oauth2-proxy.
        self.assertEqual(4, len(external_secrets))
        self.assertEqual(
            {"external-secrets.io/v1beta1"},
            {document["apiVersion"] for document in external_secrets},
        )

    def test_public_route_uses_the_existing_gateway_and_webhook_path(self):
        virtual_service = resource(self.documents, "VirtualService", "atlantis")
        self.assertEqual(["atlantis.tesserix.app"], virtual_service["spec"]["hosts"])
        self.assertEqual(
            ["istio-ingress/tesseract-gateway"],
            virtual_service["spec"]["gateways"],
        )
        paths = [
            match["uri"].get("prefix")
            for route in virtual_service["spec"]["http"]
            for match in route.get("match", [])
            if "prefix" in match["uri"]
        ]
        self.assertIn("/events", paths)
        api_route = next(
            route
            for route in virtual_service["spec"]["http"]
            if route.get("name") == "block-api"
        )
        self.assertEqual(404, api_route["directResponse"]["status"])

    def test_webhook_ingress_stays_scoped_to_the_signed_post_path(self):
        documents = render_istio_auth_policies()

        for policy_name in (
            "allow-public-api-endpoints",
            "allow-public-api-endpoints-custom",
        ):
            policy = resource(documents, "AuthorizationPolicy", policy_name)
            matching_operations = [
                target["operation"]
                for rule in policy["spec"]["rules"]
                for target in rule.get("to", [])
                if target["operation"].get("hosts")
                == ["atlantis.tesserix.app"]
            ]
            self.assertEqual(
                [
                    {
                        "hosts": ["atlantis.tesserix.app"],
                        "paths": ["/events"],
                        "methods": ["POST"],
                    }
                ],
                matching_operations,
            )

    def test_web_ui_host_is_admitted_at_the_gateway(self):
        documents = render_istio_auth_policies()

        for suffix in ("", "-custom"):
            policy = resource(
                documents,
                "AuthorizationPolicy",
                f"allow-frontend-apps-public{suffix}",
            )
            hosts = [
                host
                for rule in policy["spec"]["rules"]
                for target in rule.get("to", [])
                for host in target["operation"].get("hosts", [])
            ]
            self.assertIn("atlantis.tesserix.app", hosts)

        # The namespace is unmeshed, so a per-pod ALLOW would select nothing.
        names = {document["metadata"]["name"] for document in documents}
        self.assertNotIn("allow-atlantis-public", names)

    def test_console_is_fronted_by_zitadel_and_the_webhook_bypasses_it(self):
        virtual_service = resource(self.documents, "VirtualService", "atlantis")
        routes = virtual_service["spec"]["http"]
        order = [route["name"] for route in routes]
        # The webhook must be matched before the catch-all, or GitHub's POST is
        # answered with a login redirect.
        self.assertLess(order.index("github-webhook"), order.index("web-ui"))

        webhook = next(r for r in routes if r["name"] == "github-webhook")
        self.assertEqual(
            "atlantis.atlantis.svc.cluster.local",
            webhook["route"][0]["destination"]["host"],
        )

        web_ui = next(r for r in routes if r["name"] == "web-ui")
        self.assertEqual(
            "atlantis-ui-oauth2-proxy.atlantis.svc.cluster.local",
            web_ui["route"][0]["destination"]["host"],
        )
        self.assertEqual(4180, web_ui["route"][0]["destination"]["port"]["number"])

    def test_console_password_auth_is_gone(self):
        stateful_set = resource(self.documents, "StatefulSet", "atlantis")
        rendered = yaml.safe_dump(stateful_set)
        self.assertNotIn("ATLANTIS_WEB_BASIC_AUTH", rendered)
        self.assertNotIn("ATLANTIS_WEB_USERNAME", rendered)
        self.assertNotIn("ATLANTIS_WEB_PASSWORD", rendered)

    def test_only_the_two_named_operators_may_sign_in(self):
        config_map = resource(
            self.documents, "ConfigMap", "atlantis-ui-oauth2-proxy-emails"
        )
        emails = config_map["data"]["authenticated-emails.txt"].split()
        self.assertEqual(
            ["samyak.rout@gmail.com", "mahesh.sangawar@gmail.com"], emails
        )

    def test_proxy_authenticates_against_zitadel_without_leaking_tokens(self):
        deployment = resource(self.documents, "Deployment", "atlantis-ui-oauth2-proxy")
        args = deployment["spec"]["template"]["spec"]["containers"][0]["args"]
        self.assertIn("--provider=oidc", args)
        self.assertIn("--oidc-issuer-url=https://auth.tesserix.app", args)
        self.assertIn(
            "--redirect-url=https://atlantis.tesserix.app/oauth2/callback", args
        )
        self.assertIn(
            "--authenticated-emails-file=/etc/oauth2-proxy/authenticated-emails.txt",
            args,
        )
        self.assertIn("--code-challenge-method=S256", args)
        for cookie_flag in ("--cookie-secure=true", "--cookie-httponly=true"):
            self.assertIn(cookie_flag, args)
        # Atlantis cannot verify a token, so it must never be handed one.
        for leak in (
            "--pass-access-token=true",
            "--pass-authorization-header=true",
            "--set-authorization-header=true",
        ):
            self.assertNotIn(leak, args)

    def test_proxy_credentials_come_from_secret_manager(self):
        external_secret = resource(
            self.documents, "ExternalSecret", "atlantis-ui-oauth2-proxy"
        )
        keys = {
            entry["secretKey"]: entry["remoteRef"]["key"]
            for entry in external_secret["spec"]["data"]
        }
        self.assertEqual(
            {
                "client-id": "prod-atlantis-ui-client-id",
                "client-secret": "prod-atlantis-ui-client-secret",
                "cookie-secret": "prod-atlantis-ui-cookie-secret",
            },
            keys,
        )
        deployment = resource(self.documents, "Deployment", "atlantis-ui-oauth2-proxy")
        rendered = yaml.safe_dump(deployment)
        self.assertNotIn("client-secret: ", rendered)

    def test_proxy_may_reach_atlantis_and_atlantis_stays_otherwise_closed(self):
        network_policy = resource(self.documents, "NetworkPolicy", "atlantis-ingress")
        sources = network_policy["spec"]["ingress"][0]["from"]
        self.assertIn(
            {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "atlantis-ui-oauth2-proxy"}}},
            sources,
        )
        ports = network_policy["spec"]["ingress"][0]["ports"]
        self.assertEqual([{"protocol": "TCP", "port": 4141}], ports)

    def test_network_policy_selects_the_rendered_atlantis_pod(self):
        stateful_set = resource(self.documents, "StatefulSet", "atlantis")
        network_policy = resource(self.documents, "NetworkPolicy", "atlantis-ingress")
        pod_labels = stateful_set["spec"]["template"]["metadata"]["labels"]
        selector = network_policy["spec"]["podSelector"]["matchLabels"]
        self.assertTrue(selector.items() <= pod_labels.items())

    def test_runtime_includes_verified_kubectl_for_bootstrap_applies(self):
        stateful_set = resource(self.documents, "StatefulSet", "atlantis")
        pod_spec = stateful_set["spec"]["template"]["spec"]
        installer = next(
            container
            for container in pod_spec["initContainers"]
            if container["name"] == "install-kubectl"
        )
        self.assertIn("@sha256:", installer["image"])
        self.assertIn("sha256sum -c", installer["args"][0])

        atlantis_container = pod_spec["containers"][0]
        self.assertTrue(
            atlantis_container["securityContext"]["readOnlyRootFilesystem"]
        )
        mounts = {mount["name"]: mount for mount in atlantis_container["volumeMounts"]}
        self.assertEqual("/opt/atlantis-tools", mounts["terraform-tools"]["mountPath"])
        env = {entry["name"]: entry.get("value") for entry in atlantis_container["env"]}
        self.assertTrue(env["PATH"].startswith("/opt/atlantis-tools:"))

    def test_cluster_clients_use_fresh_keyless_credentials(self):
        for stack in ("05-k8s-bootstrap", "09-github-arc"):
            providers = (TERRAFORM_ROOT / f"stacks/{stack}/providers.tf").read_text()
            self.assertIn("gke-auth.sh", providers)
            self.assertNotIn("google_client_config", providers)

        bootstrap = (
            TERRAFORM_ROOT / "stacks/05-k8s-bootstrap/main.tf"
        ).read_text()
        self.assertIn("kubectl-gke.sh", bootstrap)
        self.assertNotRegex(bootstrap, r"(?m)^\s*(?:if\s+)?kubectl\s")

        auth_helper = (TERRAFORM_ROOT / "scripts/gke-auth.sh").read_text()
        self.assertIn("gcloud auth print-access-token", auth_helper)
        self.assertIn("Metadata-Flavor: Google", auth_helper)

        kubectl_helper = (TERRAFORM_ROOT / "scripts/kubectl-gke.sh").read_text()
        self.assertIn("certificate-authority:", kubectl_helper)
        self.assertNotIn("insecure-skip-tls-verify", kubectl_helper)

    def test_argocd_application_pins_the_upstream_chart(self):
        application = load_yaml(ROOT / "argocd/prod/infrastructure/atlantis.yaml")
        self.assertEqual("atlantis", application["spec"]["destination"]["namespace"])
        self.assertEqual("charts/thirdparty/atlantis", application["spec"]["source"]["path"])

        chart = load_yaml(ROOT / "charts/thirdparty/atlantis/Chart.yaml")
        dependency = chart["dependencies"][0]
        self.assertEqual("atlantis", dependency["name"])
        self.assertEqual("6.15.0", dependency["version"])
        values = load_yaml(ROOT / "charts/thirdparty/atlantis/values.yaml")
        self.assertRegex(values["atlantis"]["image"]["tag"], r"@sha256:[0-9a-f]{64}$")

    def test_helm_lint_registers_the_atlantis_chart_repository(self):
        chart = load_yaml(ROOT / "charts/thirdparty/atlantis/Chart.yaml")
        workflow = (ROOT / ".github/workflows/helm-lint.yaml").read_text()

        self.assertIn(
            f"helm repo add atlantis {chart['dependencies'][0]['repository']}",
            workflow,
        )


    def test_proxy_may_resolve_dns_on_the_kube_dns_cluster_ip(self):
        """A namespaceSelector alone does not match a Service ClusterIP.

        ns atlantis has no namespace-wide egress allow to fall back on, so
        without this the proxy cannot resolve the issuer and crashloops.
        """
        policy = resource(self.documents, "NetworkPolicy", "atlantis-ui-oauth2-proxy")
        dns_rule = next(
            rule
            for rule in policy["spec"]["egress"]
            if any(port["port"] == 53 for port in rule.get("ports", []))
        )
        self.assertIn({"ipBlock": {"cidr": "10.30.0.10/32"}}, dns_rule["to"])


class AtlantisApprovalRelayTests(unittest.TestCase):
    def test_new_workflows_pin_every_action_to_a_commit(self):
        for filename in ("terraform.yml", "atlantis-auto-apply.yml"):
            workflow = (ROOT / ".github/workflows" / filename).read_text()
            actions = re.findall(r"^\s*uses:\s*([^\s]+)$", workflow, re.MULTILINE)
            self.assertTrue(actions, filename)
            for action in actions:
                self.assertRegex(action, r"@[0-9a-f]{40}$", action)

    def test_relay_is_pinned_and_rechecks_approval_plan_and_checks(self):
        workflow = (ROOT / ".github/workflows/atlantis-auto-apply.yml").read_text()
        self.assertIn(
            "actions/github-script@ed597411d8f924073f98dfc5c65a23a2325f34cd",
            workflow,
        )
        for guard in (
            "pull_request_review",
            "workflow_run",
            "head.repo.fork",
            "APPROVED",
            "atlantis/plan",
            "atlantis apply",
        ):
            self.assertIn(guard, workflow)

    def test_relay_serializes_every_event_for_the_same_head(self):
        workflow = load_yaml(ROOT / ".github/workflows/atlantis-auto-apply.yml")
        concurrency_group = workflow["concurrency"]["group"]
        for head_sha in (
            "github.event.pull_request.head.sha",
            "github.event.check_run.head_sha",
            "github.event.workflow_run.head_sha",
            "github.event.sha",
        ):
            self.assertIn(head_sha, concurrency_group)

    def test_github_app_permissions_allow_atlantis_to_merge(self):
        runbook = (TERRAFORM_ROOT / "docs/ATLANTIS_RUNBOOK.md").read_text()
        self.assertIn("- Contents: read and write", runbook)

    def test_legacy_workflow_is_validation_only(self):
        workflow_path = ROOT / ".github/workflows/terraform.yml"
        workflow_text = workflow_path.read_text()
        self.assertNotRegex(workflow_text, r"terraform\s+(apply|destroy)")
        self.assertNotRegex(workflow_text, r"make\s+(apply|destroy)")
        self.assertNotIn("google-github-actions/auth", workflow_text)
        self.assertNotIn("id-token: write", workflow_text)

        workflow = load_yaml(workflow_path)
        graph = load_yaml(TERRAFORM_ROOT / "dependencies.yaml")
        matrix = workflow["jobs"]["validate"]["strategy"]["matrix"]["stack"]
        self.assertEqual(set(graph["stacks"]), set(matrix))


class AtlantisZitadelProjectTests(unittest.TestCase):
    """The console's OIDC client is reconciled, not left as a console artefact."""

    @classmethod
    def setUpClass(cls):
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
        documents = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
        config = resource(documents, "ConfigMap", "zitadel-bootstrap-config")
        desired = json.loads(config["data"]["desired.json"])
        cls.project = next(
            item for item in desired["platformProjects"] if item["name"] == "Atlantis"
        )

    def test_project_is_pinned_to_the_tesserix_org_and_its_created_id(self):
        self.assertEqual("TESSERIX", self.project["org"])
        self.assertEqual("387690151817511174", self.project["expectedId"])

    def test_oidc_client_matches_what_oauth2_proxy_sends(self):
        self.assertEqual(
            {
                "name": "atlantis-ui",
                "appType": "OIDC_APP_TYPE_WEB",
                "authMethodType": "OIDC_AUTH_METHOD_TYPE_BASIC",
                "loginBaseUri": "https://auth.tesserix.app/ui/v2/login",
                "redirectUris": ["https://atlantis.tesserix.app/oauth2/callback"],
                "postLogoutRedirectUris": ["https://atlantis.tesserix.app"],
            },
            self.project["oidcApps"][0],
        )

    def test_both_operators_are_granted_the_console_role(self):
        self.assertEqual(
            ["atlantis.admin"], [role["key"] for role in self.project["roles"]]
        )
        self.assertEqual(
            {
                "samyak.rout@gmail.com": ["atlantis.admin"],
                "mahesh.sangawar@gmail.com": ["atlantis.admin"],
            },
            {grant["login"]: grant["roles"] for grant in self.project["humanGrants"]},
        )

    def test_grant_list_matches_the_proxy_email_allowlist(self):
        chart = load_yaml(ROOT / "charts/thirdparty/atlantis/values.yaml")
        self.assertEqual(
            {grant["login"] for grant in self.project["humanGrants"]},
            set(chart["oauth2Proxy"]["allowedEmails"]),
        )


if __name__ == "__main__":
    unittest.main()
