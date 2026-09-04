from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).parents[1]


def render(chart: str, release: str, namespace: str, sets: tuple[str, ...] = ()) -> list[dict]:
    args = ["helm", "template", release, str(ROOT / chart), "--namespace", namespace]
    for item in sets:
        args += ["--set", item]
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents: list[dict], kind: str, name: str) -> dict:
    return next(d for d in documents if d.get("kind") == kind and d["metadata"]["name"] == name)


def collector_config(documents: list[dict], name: str) -> dict:
    return yaml.safe_load(resource(documents, "ConfigMap", name)["data"]["config.yaml"])


def test_gateway_fans_out_observability_and_ai_traces_to_redpanda() -> None:
    docs = render("charts/thirdparty/otel-gateway", "otel-gateway", "observability")
    config = collector_config(docs, "otel-gateway-config")
    assert set(config["service"]["pipelines"]) == {
        "logs",
        "metrics",
        "traces/observability",
        "traces/ai",
    }
    traces = config["service"]["pipelines"]["traces/ai"]
    assert traces["processors"][:2] == ["memory_limiter", "filter/ai"]
    assert traces["exporters"] == ["kafka/ai"]
    condition = config["processors"]["filter/ai"]["traces"]["span"][0]
    assert 'resource.attributes["tesserix.signal"] != "ai"' == condition
    ai = config["exporters"]["kafka/ai"]
    assert ai["traces"]["topic"] == "ai.traces"
    assert "logs" not in ai and "metrics" not in ai
    telemetry = config["exporters"]["kafka/observability"]
    assert telemetry["logs"]["topic"] == "otel.logs"
    assert telemetry["traces"]["topic"] == "otel.traces"
    assert telemetry["metrics"]["topic"] == "otel.metrics"
    for kafka in (ai, telemetry):
        assert kafka["producer"]["required_acks"] == -1
        assert kafka["sending_queue"]["storage"] == "file_storage/queue"
        assert kafka["retry_on_failure"]["max_elapsed_time"] == 0
    sts = resource(docs, "StatefulSet", "otel-gateway")
    assert sts["spec"]["replicas"] == 2
    assert sts["spec"]["template"]["spec"]["nodeSelector"] == {"workload": "infrastructure"}
    assert "tolerations" not in sts["spec"]["template"]["spec"]


def test_redpanda_has_safe_memory_and_durable_topics_for_both_consumers() -> None:
    docs = render("charts/thirdparty/redpanda", "redpanda", "observability")
    sts = resource(docs, "StatefulSet", "redpanda")
    assert sts["spec"]["replicas"] == 3
    assert sts["spec"]["template"]["spec"]["nodeSelector"] == {"workload": "infrastructure"}
    # Leave the API-server default implicit. GKE strips maxUnavailable=1,
    # otherwise Argo CD reports permanent drift for an equivalent object.
    assert "updateStrategy" not in sts["spec"]
    job = resource(docs, "Job", "redpanda-topics")
    broker_selector = sts["spec"]["selector"]["matchLabels"]
    job_labels = job["spec"]["template"]["metadata"]["labels"]
    assert not all(job_labels.get(key) == value for key, value in broker_selector.items())
    script = job["spec"]["template"]["spec"]["containers"][0]["command"][-1]
    assert 'rpk cluster health -X admin.hosts="${ADMIN_HOSTS}"' in script
    for topic in ("ai.traces", "otel.logs", "otel.traces", "otel.metrics"):
        assert f"rpk topic create {topic}" in script
    # Each topic carries retention in both its create and reconcile path.
    assert script.count("retention.ms=604800000") == 8
    values = yaml.safe_load((ROOT / "charts/thirdparty/redpanda/values.yaml").read_text())
    assert values["cluster"]["autoCreateTopics"] is False
    assert values["cluster"]["defaultTopicReplications"] == 3
    memory = values["runtime"]["memory"]
    assert memory.endswith("M")
    assert int(memory[:-1]) >= 1200


def test_ingest_routes_each_product_to_its_own_langfuse_project() -> None:
    docs = render("charts/thirdparty/otel-ingest", "otel-ingest", "observability")
    config = collector_config(docs, "otel-ingest-config")
    routes = [
        ("kora-dev", "kora", "dev"),
        ("kora-prod", "kora", "prod"),
        ("devai-prod", "devai", "prod"),
    ]
    receiver = config["receivers"]["kafka/ai"]
    assert receiver["traces"]["topics"] == ["ai.traces"]
    assert receiver["message_marking"] == {"after": True, "on_error": False}
    assert "logs" not in receiver and "metrics" not in receiver
    telemetry = config["receivers"]["kafka/observability"]
    assert telemetry["logs"]["topics"] == ["otel.logs"]
    assert telemetry["traces"]["topics"] == ["otel.traces"]
    assert telemetry["metrics"]["topics"] == ["otel.metrics"]
    clickhouse = config["exporters"]["clickhouse"]
    assert clickhouse["database"] == "otel"
    assert clickhouse["cluster_name"] == "otel"
    assert clickhouse["table_engine"] == {"name": "ReplicatedMergeTree"}
    assert clickhouse["create_schema"] is True
    table = config["connectors"]["routing"]["table"]
    assert [row["condition"] for row in table] == [
        (
            f'attributes["service.namespace"] == "{product}" and '
            f'attributes["deployment.environment.name"] == "{environment}"'
        )
        for _, product, environment in routes
    ]
    assert config["connectors"]["routing"]["default_pipelines"] == ["traces/unrouted"]
    assert config["service"]["pipelines"]["traces/ai"] == {
        "receivers": ["kafka/ai"], "processors": ["memory_limiter"], "exporters": ["routing"]
    }
    assert config["service"]["pipelines"]["traces/observability"]["exporters"] == ["clickhouse"]
    assert config["service"]["pipelines"]["logs"]["exporters"] == ["clickhouse"]
    assert config["service"]["pipelines"]["metrics"]["exporters"] == ["clickhouse"]
    for name, _, _ in routes:
        exporter = config["exporters"][f"otlphttp/{name}"]
        assert exporter["traces_endpoint"].endswith("/api/public/otel/v1/traces")
        auth = exporter["headers"]["Authorization"]
        assert auth == f"Basic ${{env:LANGFUSE_{name.upper().replace('-', '_')}_AUTH}}"
        assert exporter["sending_queue"]["enabled"] is True
        assert exporter["retry_on_failure"]["max_elapsed_time"] == "900s"
        assert config["service"]["pipelines"][f"traces/{name}"]["exporters"] == [
            f"otlphttp/{name}"
        ]
    assert config["service"]["pipelines"]["traces/unrouted"]["exporters"] == ["nop"]

    # A route is deliberately absent until its product-scoped key pair exists.
    # This prevents a missing Secret Manager object from degrading the shared
    # ingest application or sending a batch with an empty Authorization value.
    for name in ("sre-prod", "australis-prod", "ocr-prod"):
        assert f"otlphttp/{name}" not in config["exporters"]
        assert f"traces/{name}" not in config["service"]["pipelines"]


def test_ingest_builds_basic_auth_only_for_enabled_product_routes() -> None:
    docs = render("charts/thirdparty/otel-ingest", "otel-ingest", "observability")
    deployment = resource(docs, "Deployment", "otel-ingest")
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    env = {entry["name"]: entry for entry in container["env"]}
    assert env["LANGFUSE_KORA_DEV_AUTH"]["valueFrom"]["secretKeyRef"] == {
        "name": "otel-ingest-langfuse-kora-dev", "key": "auth", "optional": True
    }
    secret = resource(docs, "ExternalSecret", "otel-ingest-langfuse-kora-dev")
    assert secret["spec"]["secretStoreRef"] == {"kind": "SecretStore", "name": "otel-ingest-gcp"}
    assert [d["remoteRef"]["key"] for d in secret["spec"]["data"]] == [
        "dev-kora-langfuse-public-key", "dev-kora-langfuse-secret-key"
    ]
    assert all(
        document.get("metadata", {}).get("name") != "otel-ingest-langfuse-sre-prod"
        for document in docs
    )
    template = secret["spec"]["target"]["template"]
    assert template["engineVersion"] == "v2"
    assert template["data"]["auth"] == '{{ printf "%s:%s" .publicKey .secretKey | b64enc }}'
    assert deployment["spec"]["template"]["spec"]["nodeSelector"] == {"workload": "infrastructure"}

    service_account = resource(docs, "ServiceAccount", "otel-ingest-secrets")
    assert service_account["metadata"]["annotations"] == {
        "iam.gke.io/gcp-service-account": (
            "otel-ingest-secrets@tesseracthub-480811.iam.gserviceaccount.com"
        )
    }
    store = resource(docs, "SecretStore", "otel-ingest-gcp")
    assert store["spec"]["provider"]["gcpsm"] == {
        "projectID": "tesseracthub-480811",
        "auth": {
            "workloadIdentity": {
                "clusterLocation": "asia-south1",
                "clusterName": "tesseract-prod-in-gke",
                "clusterProjectID": "tesseracthub-480811",
                "serviceAccountRef": {"name": "otel-ingest-secrets"},
            }
        },
    }


def test_ingest_secret_identity_has_only_route_project_keys() -> None:
    terraform = (ROOT / "terraform-new/environments/prod/terraform.tfvars").read_text()
    start = terraform.index('name          = "otel-ingest-secrets"')
    block = terraform[start : terraform.index("\n  },", start)]
    expected = {
        f"{environment}-kora-langfuse-{key}-key"
        for environment in ("dev", "prod")
        for key in ("public", "secret")
    }
    assert {
        line.split('secret_id = "', 1)[1].split('"', 1)[0]
        for line in block.splitlines()
        if 'secret_id = "' in line
    } == expected
    assert "langfuse-org" not in block
    assert "project_roles = []" in block


def test_every_ai_agent_exports_to_the_gateway_with_its_product_and_may_reach_it() -> None:
    cases = [
        ("charts/apps/kora-ai-agents", "kora-ai-agents", "kora", "kora", ("image.digest=sha256:" + "a" * 64,)),
        (
            "charts/apps/sre-ai-agent",
            "sre-ai-agent",
            "ai-agents",
            "sre",
            ("enabled=true", "image.digest=sha256:" + "a" * 64),
        ),
    ]
    for chart, release, namespace, product, sets in cases:
        docs = render(chart, release, namespace, sets)
        deployment = resource(docs, "Deployment", release)
        env = {
            entry["name"]: entry.get("value")
            for entry in deployment["spec"]["template"]["spec"]["containers"][0]["env"]
        }
        assert env["AGENT_TELEMETRY_ENDPOINT"] == (
            "http://otel-gateway.observability.svc.cluster.local:4318/v1/traces"
        )
        assert env["AGENT_TELEMETRY_PRODUCT"] == product
        assert env["AGENT_TELEMETRY_SERVICE_NAME"] == release
        assert env["AGENT_TELEMETRY_ENVIRONMENT"] == "prod"
        assert env["AGENT_TELEMETRY_RELEASE"] == "main-" + "a" * 12
        policy = resource(docs, "NetworkPolicy", release)
        egress = [
            rule for rule in policy["spec"]["egress"]
            if any(
                peer.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name")
                == "observability"
                for peer in rule["to"]
            )
        ]
        assert len(egress) == 1
        assert egress[0]["to"][0]["podSelector"]["matchLabels"] == {"app.kubernetes.io/name": "otel-gateway"}
        assert egress[0]["ports"] == [{"port": 4318, "protocol": "TCP"}]


def test_sre_has_an_onboarding_claim_so_its_langfuse_project_and_keys_exist() -> None:
    claim = yaml.safe_load((ROOT / "k8s/operators/evals-onboarding/claims/sre.yaml").read_text())
    assert claim["kind"] == "EvalOnboarding" and claim["metadata"]["name"] == "sre"
    kustomization = yaml.safe_load(
        (ROOT / "k8s/operators/evals-onboarding/claims/kustomization.yaml").read_text()
    )
    assert "sre.yaml" in kustomization["resources"]
