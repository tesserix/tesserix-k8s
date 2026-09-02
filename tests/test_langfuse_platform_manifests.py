from __future__ import annotations

import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def documents(path: str) -> list[dict]:
    return [
        item
        for item in yaml.safe_load_all((ROOT / path).read_text())
        if isinstance(item, dict)
    ]


def resource(items: list[dict], kind: str, name: str) -> dict:
    return next(
        item
        for item in items
        if item.get("kind") == kind and item.get("metadata", {}).get("name") == name
    )


def test_infra_postgres_owns_langfuse_role_and_database() -> None:
    result = subprocess.run(
        [
            "helm",
            "template",
            "infra-postgres",
            str(ROOT / "charts/apps/infra-postgres"),
            "--namespace",
            "infra",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    items = [item for item in yaml.safe_load_all(result.stdout) if item]
    cluster = resource(items, "Cluster", "infra-postgres")
    database = resource(items, "Database", "langfuse")
    secret = resource(items, "ExternalSecret", "infra-postgres-langfuse")
    role = next(
        item
        for item in cluster["spec"]["managed"]["roles"]
        if item["name"] == "langfuse"
    )
    assert role["passwordSecret"] == {"name": "infra-postgres-langfuse"}
    assert database["spec"] == {
        "name": "langfuse",
        "owner": "langfuse",
        "cluster": {"name": "infra-postgres"},
        "ensure": "present",
        "databaseReclaimPolicy": "retain",
    }
    assert (
        secret["spec"]["data"][0]["remoteRef"]["key"]
        == "prod-langfuse-postgresql-password"
    )


def test_langfuse_release_is_pinned_external_hardened_and_manual() -> None:
    application = documents("argocd/prod/infrastructure/langfuse.yaml")[0]
    source = application["spec"]["source"]
    values = yaml.safe_load(source["helm"]["values"])
    assert (source["repoURL"], source["chart"], source["targetRevision"]) == (
        "ghcr.io/langfuse/langfuse-k8s/charts",
        "langfuse",
        "2.1.0",
    )
    assert "automated" not in application["spec"].get("syncPolicy", {})
    assert values["postgresql"]["deploy"] is False
    assert values["postgresql"]["host"] == "infra-postgres-rw.infra.svc.cluster.local"
    assert values["clickhouse"]["deploy"] is False
    assert (
        values["clickhouse"]["host"] == "clickhouse-ha.observability.svc.cluster.local"
    )
    assert values["redis"]["deploy"] is False
    assert values["redis"]["host"] == "global-valkey-queue.global.svc.cluster.local"
    assert values["redis"]["auth"]["username"] is None
    assert values["s3"] == {
        "deploy": False,
        "storageProvider": "gcs",
        "bucket": "tesserix-langfuse-prod-in",
        "region": "asia-south1",
        "forcePathStyle": False,
        "gcs": {"credentials": {"value": ""}},
    }
    app = values["langfuse"]
    assert app["web"]["replicas"] == app["worker"]["replicas"] == 2
    assert (
        app["web"]["pdb"]["minAvailable"] == app["worker"]["pdb"]["minAvailable"] == 1
    )
    assert app["securityContext"]["readOnlyRootFilesystem"] is True
    assert app["podSecurityContext"]["runAsNonRoot"] is True
    env = {item["name"]: item for item in app["additionalEnv"]}
    assert env["CLICKHOUSE_CLUSTER_NAME"]["value"] == "otel"
    assert env["LANGFUSE_INIT_PROJECT_ID"]["value"] == "devai"
    assert app["nextauth"]["url"] == "https://langfuse.tesserix.app"
    assert app["auth"]["disableUsernamePassword"] is True


def test_secrets_routing_and_devai_export_are_wired() -> None:
    external = resource(
        documents("external-secrets/prod/observability/langfuse-secrets.yaml"),
        "ExternalSecret",
        "langfuse-secrets",
    )
    mappings = {
        item["secretKey"]: item["remoteRef"]["key"] for item in external["spec"]["data"]
    }
    assert mappings["postgres-password"] == "prod-langfuse-postgresql-password"
    assert mappings["project-public-key"] == "prod-devai-langfuse-public-key"
    assert mappings["project-secret-key"] == "prod-devai-langfuse-secret-key"
    route = resource(
        documents("manifests/observability-istio/virtualservice.yaml"),
        "VirtualService",
        "langfuse",
    )
    assert route["spec"]["hosts"] == ["langfuse.tesserix.app"]
    assert route["spec"]["http"][0]["route"][0]["destination"] == {
        "host": "langfuse-web.observability.svc.cluster.local",
        "port": {"number": 3000},
    }
    values = yaml.safe_load(
        (ROOT / "charts/apps/devai-api/values-prod.yaml").read_text()
    )
    assert values["env"]["DEVAI_TELEMETRY_PROVIDER"] == "langfuse"
    assert values["env"]["DEVAI_LANGFUSE_PUBLIC_URL"] == "https://langfuse.tesserix.app"
    devai = resource(
        documents("external-secrets/prod/devai/externalsecret.yaml"),
        "ExternalSecret",
        "devai-langfuse-secrets",
    )
    devai_keys = {
        item["secretKey"]: item["remoteRef"]["key"] for item in devai["spec"]["data"]
    }
    assert devai_keys == {
        "DEVAI_LANGFUSE_PUBLIC_KEY": "prod-devai-langfuse-public-key",
        "DEVAI_LANGFUSE_SECRET_KEY": "prod-devai-langfuse-secret-key",
    }


def test_parked_dependencies_are_revival_ready() -> None:
    clickhouse = yaml.safe_load(
        (ROOT / "charts/thirdparty/clickhouse-ha/values.yaml").read_text()
    )
    queue = yaml.safe_load(
        (ROOT / "charts/apps/global-valkey/values-queue.yaml").read_text()
    )
    assert clickhouse["replicaCount"] == 0
    assert tuple(int(part) for part in clickhouse["image"]["tag"].split(".")[:2]) >= (
        25,
        12,
    )
    assert "observability" in queue["networkPolicy"]["allowedNamespaces"]
