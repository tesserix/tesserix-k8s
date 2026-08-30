from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).parents[1]


def load(path: str) -> dict:
    return yaml.safe_load((ROOT / path).read_text())


def load_all(path: str) -> list[dict]:
    return [document for document in yaml.safe_load_all((ROOT / path).read_text()) if document]


def render_chart() -> list[dict]:
    result = subprocess.run(
        [
            "helm",
            "template",
            "sre-ai-agent",
            str(ROOT / "charts/apps/sre-ai-agent"),
            "--namespace",
            "ai-agents",
            "--set",
            "enabled=true",
            "--set",
            f"image.digest=sha256:{'a' * 64}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def render_registry_chart() -> list[dict]:
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


def resource(documents: list[dict], kind: str, name: str) -> dict:
    return next(
        document
        for document in documents
        if document.get("kind") == kind and document.get("metadata", {}).get("name") == name
    )


def test_the_sre_agent_application_owns_a_product_neutral_namespace() -> None:
    application = load("argocd/prod/apps/ai-apps/sre-ai-agent.yaml")
    resources = load("argocd/prod/apps/ai-apps/kustomization.yaml")["resources"]

    assert "sre-ai-agent.yaml" in resources
    assert application["spec"]["project"] == "infrastructure"
    assert application["spec"]["source"]["path"] == "charts/apps/sre-ai-agent"
    assert application["spec"]["destination"]["namespace"] == "ai-agents"
    assert application["spec"]["syncPolicy"]["automated"] == {
        "prune": True,
        "selfHeal": True,
    }
    assert "CreateNamespace=true" in application["spec"]["syncPolicy"]["syncOptions"]


def test_the_ai_agents_namespace_has_ambient_identity_and_a_waypoint() -> None:
    values = load("charts/thirdparty/istio-config/values.yaml")

    assert "ai-agents" in values["sidecarInjection"]["namespaces"]
    assert "ai-agents" in values["ambient"]["waypointNamespaces"]
    assert values["sidecarInjection"]["protectedTiers"]["ai-agents"] == "application"


def test_the_sre_workload_is_ha_pinned_and_hardened() -> None:
    documents = render_chart()
    deployment = resource(documents, "Deployment", "sre-ai-agent")
    pod = deployment["spec"]["template"]["spec"]
    container = pod["containers"][0]
    pdb = resource(documents, "PodDisruptionBudget", "sre-ai-agent")

    assert deployment["spec"]["replicas"] == 2
    assert deployment["spec"]["strategy"]["rollingUpdate"] == {
        "maxSurge": 1,
        "maxUnavailable": 0,
    }
    assert {constraint["topologyKey"] for constraint in pod["topologySpreadConstraints"]} == {
        "topology.kubernetes.io/zone",
        "kubernetes.io/hostname",
    }
    assert pdb["spec"]["minAvailable"] == 1
    assert container["image"] == (
        "asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/"
        f"tesserix/ai-agents-sre@sha256:{'a' * 64}"
    )
    assert pod["serviceAccountName"] == "sre-ai-agent"
    assert pod["automountServiceAccountToken"] is True
    assert pod["terminationGracePeriodSeconds"] >= 100
    assert pod["securityContext"]["runAsUser"] == 10001
    assert container["securityContext"] == {
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": True,
    }
    assert container["readinessProbe"]["httpGet"]["path"] == "/readyz"
    assert container["livenessProbe"]["httpGet"]["path"] == "/healthz"
    assert container["resources"]["requests"] == {"memory": "256Mi"}
    assert container["resources"]["limits"] == {"memory": "512Mi"}


def test_cluster_access_is_read_only_and_cannot_read_secrets() -> None:
    documents = render_chart()
    role = resource(documents, "ClusterRole", "sre-ai-agent-reader")
    binding = resource(documents, "ClusterRoleBinding", "sre-ai-agent-reader")
    grants = {
        (tuple(rule["apiGroups"]), tuple(rule["resources"])): tuple(rule["verbs"])
        for rule in role["rules"]
    }

    assert grants[(('',), ('pods', 'events'))] == ("get", "list", "watch")
    assert grants[(('',), ('pods/log',))] == ("get",)
    assert grants[(('apps',), ('deployments',))] == ("get", "list", "watch")
    assert all("secrets" not in resources for _, resources in grants)
    assert all(set(verbs) <= {"get", "list", "watch"} for verbs in grants.values())
    assert binding["roleRef"] == {
        "apiGroup": "rbac.authorization.k8s.io",
        "kind": "ClusterRole",
        "name": "sre-ai-agent-reader",
    }
    assert binding["subjects"] == [
        {"kind": "ServiceAccount", "name": "sre-ai-agent", "namespace": "ai-agents"}
    ]


def test_workload_and_gateway_receive_distinct_secret_projections() -> None:
    documents = render_chart()
    workload = resource(documents, "ExternalSecret", "sre-ai-agent")
    upstream = resource(documents, "ExternalSecret", "sre-ai-agent-upstream")
    workload_data = {
        entry["secretKey"]: entry["remoteRef"]["key"] for entry in workload["spec"]["data"]
    }

    assert workload["metadata"]["namespace"] == "ai-agents"
    assert workload_data == {
        "API_KEY": "prod-sre-ai-upstream-token",
        "GATEWAY_API_KEY": "prod-sre-ai-gateway-api-key",
    }
    assert upstream["metadata"]["namespace"] == "agentgateway-system"
    assert upstream["spec"]["data"] == [
        {
            "secretKey": "token",
            "remoteRef": {"key": "prod-sre-ai-upstream-token"},
        }
    ]
    assert not [document for document in documents if document.get("kind") == "Secret"]


def test_registry_accepts_a_separate_tesserix_scoped_sre_deploy_key() -> None:
    documents = render_registry_chart()
    deployment = resource(documents, "Deployment", "agentregistry")
    external_secret = resource(documents, "ExternalSecret", "agentregistry-secrets")
    env = {
        entry["name"]: entry
        for entry in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    mappings = {
        item["secretKey"]: item["remoteRef"]["key"]
        for item in external_secret["spec"]["data"]
    }

    assert mappings["SRE_DEPLOY_KEY_SHA256"] == (
        "prod-agentic-registry-sre-deploy-key-sha256"
    )
    assert env["SRE_DEPLOY_KEY_SHA256"]["valueFrom"]["secretKeyRef"] == {
        "name": "agentregistry-secrets",
        "key": "SRE_DEPLOY_KEY_SHA256",
    }
    configured = env["AUTH_DEPLOY_KEYS"]["value"]
    assert "kora=$(KORA_DEPLOY_KEY_SHA256)" in configured
    assert "devai=$(DEVAI_DEPLOY_KEY_SHA256)" in configured
    assert "tesserix=$(SRE_DEPLOY_KEY_SHA256)" in configured


def test_sre_agent_uses_the_shared_runtime_listener_and_backend_identity() -> None:
    documents = render_chart()
    backend = resource(documents, "AgentgatewayBackend", "sre-ai-agent")
    route = resource(documents, "HTTPRoute", "sre-ai-agent")
    policy = resource(documents, "AgentgatewayPolicy", "sre-ai-agent")

    assert backend["metadata"]["namespace"] == "agentgateway-system"
    assert backend["spec"]["a2a"] == {
        "host": "sre-ai-agent.ai-agents.svc.cluster.local",
        "port": 8080,
    }
    assert route["metadata"]["namespace"] == "agentgateway-system"
    assert route["spec"]["parentRefs"] == [
        {
            "group": "gateway.networking.k8s.io",
            "kind": "Gateway",
            "name": "agentgateway-mcp",
            "sectionName": "runtime",
        }
    ]
    assert route["spec"]["rules"][0]["matches"] == [
        {
            "path": {
                "type": "PathPrefix",
                "value": "/a2a/v1/sre-investigator",
            }
        }
    ]
    assert route["spec"]["rules"][0]["backendRefs"] == [
        {
            "group": "agentgateway.dev",
            "kind": "AgentgatewayBackend",
            "name": "sre-ai-agent",
            "weight": 1,
        }
    ]
    assert policy["spec"]["targetRefs"] == [
        {
            "group": "agentgateway.dev",
            "kind": "AgentgatewayBackend",
            "name": "sre-ai-agent",
        }
    ]
    assert "traffic" not in policy["spec"]
    backend_auth = policy["spec"]["backend"]["auth"]
    assert backend_auth["secretRef"] == {
        "name": "sre-ai-agent-upstream",
        "key": "token",
    }
    assert backend_auth["location"] == {
        "header": {"name": "Authorization", "prefix": "Bearer "}
    }


def test_network_and_mesh_policy_expose_only_the_reviewed_service_paths() -> None:
    documents = render_chart()
    network = resource(documents, "NetworkPolicy", "sre-ai-agent")
    gateway_egress = resource(
        documents,
        "NetworkPolicy",
        "allow-agentgateway-mcp-to-sre-ai-agent",
    )
    authorization = resource(documents, "AuthorizationPolicy", "sre-ai-agent")

    assert network["spec"]["policyTypes"] == ["Ingress", "Egress"]
    ingress_namespaces = {
        source["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
        for rule in network["spec"]["ingress"]
        for source in rule["from"]
    }
    assert ingress_namespaces == {"ai-agents", "agentgateway-system"}
    gateway_destinations = [
        destination
        for rule in network["spec"]["egress"]
        for destination in rule.get("to", [])
        if destination.get("podSelector", {}).get("matchLabels", {}).get(
            "gateway.networking.k8s.io/gateway-name"
        )
        == "ai-gateway"
    ]
    assert gateway_destinations
    api_cidrs = {
        destination["ipBlock"]["cidr"]
        for rule in network["spec"]["egress"]
        for destination in rule.get("to", [])
        if "ipBlock" in destination
    }
    assert {"10.30.0.1/32", "172.16.0.0/28"} <= api_cidrs
    assert "172.16.0.0/12" not in api_cidrs
    assert gateway_egress["metadata"]["namespace"] == "agentgateway-system"
    assert gateway_egress["spec"]["podSelector"]["matchLabels"] == {
        "gateway.networking.k8s.io/gateway-name": "agentgateway-mcp"
    }
    assert gateway_egress["spec"]["egress"][0]["to"] == [
        {
            "namespaceSelector": {
                "matchLabels": {"kubernetes.io/metadata.name": "ai-agents"}
            }
        }
    ]
    service_rule = authorization["spec"]["rules"][0]
    assert service_rule["from"][0]["source"]["principals"] == [
        "cluster.local/ns/agentgateway-system/sa/agentgateway-mcp"
    ]
    assert service_rule["to"][0]["operation"] == {
        "methods": ["GET", "POST"],
        "paths": ["/a2a/v1/sre-investigator*"],
    }
    assert authorization["spec"]["rules"][1]["to"][0]["operation"] == {
        "methods": ["GET"],
        "paths": ["/healthz", "/readyz"],
    }


def test_only_the_sre_service_account_can_use_the_shared_vertex_route() -> None:
    principal = "cluster.local/ns/ai-agents/sa/sre-ai-agent"
    values = load("charts/apps/devai-ai-gateway/values.yaml")
    policies = load_all("manifests/agentic-istio/authorization-policy.yaml")
    allow = resource(policies, "AuthorizationPolicy", "ai-gateway-authz")
    deny = resource(policies, "AuthorizationPolicy", "ai-gateway-deny-non-devai")

    assert principal in values["authorizationPolicy"]["allowedPrincipals"]
    assert principal in allow["spec"]["rules"][0]["from"][0]["source"]["principals"]
    assert principal in deny["spec"]["rules"][0]["from"][0]["source"]["notPrincipals"]


def test_sre_agent_alerts_and_operating_docs_cover_failure_and_rollback() -> None:
    documents = render_chart()
    rules = resource(documents, "PrometheusRule", "sre-ai-agent")
    alerts = {
        rule["alert"]: rule
        for group in rules["spec"]["groups"]
        for rule in group["rules"]
    }

    assert set(alerts) == {
        "SREAIInvestigatorHADegraded",
        "SREAIInvestigatorRestarting",
        "SREAIInvestigatorUnavailable",
    }
    for alert in alerts.values():
        assert alert["labels"]["owner"] == "ai-platform"
        assert alert["annotations"]["runbook_url"].endswith(
            "docs/runbooks/sre-ai-agent.md"
        )

    runbook = (ROOT / "docs/runbooks/sre-ai-agent.md").read_text()
    assert "agentgateway-system" in runbook
    assert "ai-agents" in runbook
    assert "remove or disable the HTTPRoute first" in runbook

    decision = (ROOT / "docs/adr/0005-standalone-sre-ai-agent.md").read_text()
    for contract in (
        "two replicas",
        "60 requests per minute per replica",
        "Failure behavior",
        "Cost",
        "Rollback",
    ):
        assert contract in decision
