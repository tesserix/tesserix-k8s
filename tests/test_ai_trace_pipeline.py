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


def test_gateway_accepts_only_ai_traces_and_spools_to_redpanda() -> None:
    docs = render("charts/thirdparty/otel-gateway", "otel-gateway", "observability")
    config = collector_config(docs, "otel-gateway-config")
    assert set(config["service"]["pipelines"]) == {"traces"}
    traces = config["service"]["pipelines"]["traces"]
    assert traces["processors"][:2] == ["memory_limiter", "filter/ai"]
    assert traces["exporters"] == ["kafka"]
    condition = config["processors"]["filter/ai"]["traces"]["span"][0]
    assert 'resource.attributes["tesserix.signal"] != "ai"' == condition
    kafka = config["exporters"]["kafka"]
    assert kafka["traces"]["topic"] == "ai.traces"
    assert "logs" not in kafka and "metrics" not in kafka
    assert kafka["producer"]["required_acks"] == -1
    assert kafka["sending_queue"]["storage"] == "file_storage/queue"
    assert kafka["retry_on_failure"]["max_elapsed_time"] == 0
    sts = resource(docs, "StatefulSet", "otel-gateway")
    assert sts["spec"]["replicas"] == 2
    assert sts["spec"]["template"]["spec"]["nodeSelector"] == {"workload": "infrastructure"}
    assert "tolerations" not in sts["spec"]["template"]["spec"]


def test_redpanda_declares_only_the_ai_topic_with_a_week_of_retention() -> None:
    docs = render("charts/thirdparty/redpanda", "redpanda", "observability")
    sts = resource(docs, "StatefulSet", "redpanda")
    assert sts["spec"]["replicas"] == 3
    assert sts["spec"]["template"]["spec"]["nodeSelector"] == {"workload": "infrastructure"}
    job = resource(docs, "Job", "redpanda-topics")
    script = job["spec"]["template"]["spec"]["containers"][0]["command"][-1]
    assert "rpk topic create ai.traces" in script
    assert "retention.ms=604800000" in script
    assert "otel.logs" not in script and "otel.metrics" not in script
    values = yaml.safe_load((ROOT / "charts/thirdparty/redpanda/values.yaml").read_text())
    assert values["cluster"]["autoCreateTopics"] is False
    assert values["cluster"]["defaultTopicReplications"] == 3


def test_ingest_routes_each_product_to_its_own_langfuse_project() -> None:
    docs = render("charts/thirdparty/otel-ingest", "otel-ingest", "observability")
    config = collector_config(docs, "otel-ingest-config")
    products = ["kora", "sre", "devai", "australis", "ocr"]
    receiver = config["receivers"]["kafka"]
    assert receiver["traces"]["topics"] == ["ai.traces"]
    assert receiver["message_marking"] == {"after": True, "on_error": False}
    assert "logs" not in receiver and "metrics" not in receiver
    assert "clickhouse" not in config["exporters"]
    table = config["connectors"]["routing"]["table"]
    assert [row["condition"] for row in table] == [
        f'attributes["service.namespace"] == "{p}"' for p in products
    ]
    assert config["connectors"]["routing"]["default_pipelines"] == ["traces/unrouted"]
    assert config["service"]["pipelines"]["traces/in"] == {
        "receivers": ["kafka"], "processors": ["memory_limiter"], "exporters": ["routing"]
    }
    for product in products:
        exporter = config["exporters"][f"otlphttp/{product}"]
        assert exporter["traces_endpoint"].endswith("/api/public/otel/v1/traces")
        auth = exporter["headers"]["Authorization"]
        assert auth == f"Basic ${{env:LANGFUSE_{product.upper()}_AUTH}}"
        assert exporter["sending_queue"]["enabled"] is True
        assert exporter["retry_on_failure"]["max_elapsed_time"] == "900s"
        assert config["service"]["pipelines"][f"traces/{product}"]["exporters"] == [
            f"otlphttp/{product}"
        ]
    assert config["service"]["pipelines"]["traces/unrouted"]["exporters"] == ["nop"]


def test_ingest_builds_basic_auth_from_mirrored_keys_and_tolerates_missing_ones() -> None:
    docs = render("charts/thirdparty/otel-ingest", "otel-ingest", "observability")
    deployment = resource(docs, "Deployment", "otel-ingest")
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    env = {entry["name"]: entry for entry in container["env"]}
    assert env["LANGFUSE_KORA_AUTH"]["valueFrom"]["secretKeyRef"] == {
        "name": "otel-ingest-langfuse-kora", "key": "auth", "optional": True
    }
    secret = resource(docs, "ExternalSecret", "otel-ingest-langfuse-sre")
    assert secret["spec"]["secretStoreRef"] == {"kind": "ClusterSecretStore", "name": "gcp-secret-store"}
    assert [d["remoteRef"]["key"] for d in secret["spec"]["data"]] == [
        "prod-sre-langfuse-public-key", "prod-sre-langfuse-secret-key"
    ]
    template = secret["spec"]["target"]["template"]
    assert template["engineVersion"] == "v2"
    assert template["data"]["auth"] == '{{ printf "%s:%s" .publicKey .secretKey | b64enc }}'
    assert deployment["spec"]["template"]["spec"]["nodeSelector"] == {"workload": "infrastructure"}


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
