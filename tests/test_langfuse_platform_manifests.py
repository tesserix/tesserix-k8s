from __future__ import annotations

import subprocess
import xml.etree.ElementTree as ET
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
    project = documents("argocd/prod/projects/infrastructure.yaml")[0]
    clickhouse_render = subprocess.run(
        [
            "helm",
            "template",
            "clickhouse",
            str(ROOT / "charts/thirdparty/clickhouse-ha"),
            "--namespace",
            "observability",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    clickhouse = [item for item in yaml.safe_load_all(clickhouse_render.stdout) if item]
    clickhouse_service = resource(clickhouse, "Service", "clickhouse")
    source = application["spec"]["source"]
    values = yaml.safe_load(source["helm"]["values"])
    assert (source["repoURL"], source["chart"], source["targetRevision"]) == (
        "ghcr.io/langfuse/langfuse-k8s/charts",
        "langfuse",
        "2.1.0",
    )
    assert "automated" not in application["spec"].get("syncPolicy", {})
    assert source["repoURL"] in project["spec"]["sourceRepos"]
    assert values["postgresql"]["deploy"] is False
    assert values["postgresql"]["host"] == "infra-postgres-rw.infra.svc.cluster.local"
    assert values["clickhouse"]["deploy"] is False
    assert values["clickhouse"]["host"] == (
        f"{clickhouse_service['metadata']['name']}.observability.svc.cluster.local"
    )
    assert values["clickhouse"]["database"] == "langfuse"
    assert values["redis"]["deploy"] is False
    assert values["redis"]["host"] == "global-valkey-queue.global.svc.cluster.local"
    assert values["redis"]["auth"]["username"] is None
    assert values["redis"]["auth"]["database"] == 1
    assert values["s3"] == {
        "deploy": False,
        "storageProvider": "gcs",
        "bucket": "tesserix-langfuse-prod-in",
        "region": "asia-south1",
        "forcePathStyle": False,
        "gcs": {"credentials": {"value": ""}},
    }
    app = values["langfuse"]
    assert app["web"]["image"]["tag"] == (
        "4.27.0@sha256:c9e2cab8469a5d7353e86a3252b02c52ac94ef31288ce2639ee01aabf5e4222b"
    )
    assert app["worker"]["image"]["tag"] == (
        "4.27.0@sha256:091a85c3c54bf5fff7cc0073a7f35a52861cc0e30d33dd05569fe3ed66b15d8d"
    )
    assert app["web"]["replicas"] == app["worker"]["replicas"] == 2
    assert app["web"]["livenessProbe"]["initialDelaySeconds"] == 90
    assert app["web"]["readinessProbe"]["initialDelaySeconds"] == 30
    assert app["worker"]["livenessProbe"]["initialDelaySeconds"] == 90
    assert app["web"]["resources"] == {
        "requests": {"memory": "1Gi"},
        "limits": {"memory": "2Gi"},
    }
    assert app["nodeSelector"] == {"workload": "infrastructure"}
    assert (
        app["web"]["pdb"]["minAvailable"] == app["worker"]["pdb"]["minAvailable"] == 1
    )
    assert app["securityContext"]["readOnlyRootFilesystem"] is True
    assert app["podSecurityContext"]["runAsNonRoot"] is True
    env = {item["name"]: item for item in app["additionalEnv"]}
    assert env["CLICKHOUSE_CLUSTER_NAME"]["value"] == "default"
    assert env["LANGFUSE_INIT_PROJECT_ID"]["value"] == "devai"
    assert app["nextauth"]["url"] == "https://langfuse.tesserix.app"
    assert app["auth"] == {"disableUsernamePassword": True}
    assert app["features"]["signUpDisabled"] is False
    expected_oidc_values = {
        "AUTH_CUSTOM_ISSUER": "https://auth.tesserix.app",
        "AUTH_CUSTOM_NAME": "Tesserix",
        "AUTH_CUSTOM_SCOPE": "openid email profile",
        "AUTH_CUSTOM_CLIENT_AUTH_METHOD": "client_secret_basic",
        "AUTH_CUSTOM_CHECKS": "pkce,state",
        "AUTH_CUSTOM_ALLOW_ACCOUNT_LINKING": "true",
        "AUTH_CUSTOM_ID_TOKEN": "true",
        "AUTH_CUSTOM_FETCH_USERINFO": "true",
    }
    for name, value in expected_oidc_values.items():
        assert env[name] == {"name": name, "value": value}
    assert env["AUTH_CUSTOM_CLIENT_ID"]["valueFrom"] == {
        "secretKeyRef": {"name": "langfuse-secrets", "key": "zitadel-client-id"}
    }
    assert env["AUTH_CUSTOM_CLIENT_SECRET"]["valueFrom"] == {
        "secretKeyRef": {
            "name": "langfuse-secrets",
            "key": "zitadel-client-secret",
        }
    }


def test_langfuse_pods_accept_only_gateway_and_application_traffic() -> None:
    policy = resource(
        documents("manifests/observability-istio/networkpolicy-langfuse.yaml"),
        "NetworkPolicy",
        "langfuse",
    )
    assert policy["metadata"]["namespace"] == "observability"
    assert policy["spec"]["podSelector"] == {
        "matchLabels": {"app.kubernetes.io/name": "langfuse"}
    }
    assert policy["spec"]["policyTypes"] == ["Ingress"]
    (rule,) = policy["spec"]["ingress"]
    assert rule["ports"] == [{"protocol": "TCP", "port": 3000}]
    sources = rule["from"]
    assert {
        "namespaceSelector": {
            "matchLabels": {"kubernetes.io/metadata.name": "istio-ingress"}
        }
    } in sources
    assert {
        "namespaceSelector": {
            "matchLabels": {"kubernetes.io/metadata.name": "evals-operator"}
        }
    } in sources
    assert {
        "namespaceSelector": {"matchLabels": {"tesserix.io/tier": "application"}}
    } in sources
    assert {"podSelector": {}} in sources
    assert len(sources) == 4


def test_secrets_routing_and_devai_export_are_wired() -> None:
    secrets_app = documents(
        "argocd/prod/infrastructure/external-secrets-resources.yaml"
    )[0]
    assert secrets_app["spec"]["ignoreDifferences"] == [
        {
            "group": "external-secrets.io",
            "kind": "ExternalSecret",
            "jsonPointers": ["/spec/refreshPolicy"],
        }
    ]
    external = resource(
        documents("external-secrets/prod/observability/langfuse-secrets.yaml"),
        "ExternalSecret",
        "langfuse-secrets",
    )
    mappings = {
        item["secretKey"]: item["remoteRef"]["key"] for item in external["spec"]["data"]
    }
    assert external["spec"]["target"]["deletionPolicy"] == "Retain"
    assert mappings["postgres-password"] == "prod-langfuse-postgresql-password"
    assert mappings["project-public-key"] == "prod-devai-langfuse-public-key"
    assert mappings["project-secret-key"] == "prod-devai-langfuse-secret-key"
    assert mappings["zitadel-client-id"] == "prod-langfuse-zitadel-client-id"
    assert mappings["zitadel-client-secret"] == "prod-langfuse-zitadel-client-secret"
    assert "google-client-id" not in mappings
    assert "google-client-secret" not in mappings
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
    devai_render = subprocess.run(
        [
            "helm",
            "template",
            "devai-api",
            str(ROOT / "charts/apps/devai-api"),
            "--namespace",
            "devai",
            "-f",
            str(ROOT / "charts/apps/devai-api/values-prod.yaml"),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    devai_items = [item for item in yaml.safe_load_all(devai_render.stdout) if item]
    for deployment_name in ("devai-api", "devai-api-worker"):
        deployment = resource(devai_items, "Deployment", deployment_name)
        assert set(
            deployment["spec"]["template"]["metadata"]["annotations"][
                "secret.reloader.stakater.com/reload"
            ].split(",")
        ) == {"devai-langfuse-secrets", "devai-document-intelligence-kora-dev"}
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


def test_langfuse_zitadel_claim_is_restricted_to_approved_users() -> None:
    claim = resource(
        documents("k8s/operators/zitadel/claims/langfuse.yaml"),
        "ZitadelProject",
        "langfuse",
    )
    assert claim["spec"]["organization"] == "TESSERIX"
    assert claim["spec"]["access"]["mode"] == "restricted"
    assert claim["spec"]["access"]["members"] == [
        {"email": "samyak.rout@gmail.com", "roles": ["admin"]},
        {"email": "mahesh.sangawar@gmail.com", "roles": ["admin"]},
    ]


def test_dependencies_run_on_the_shared_infrastructure_pool() -> None:
    clickhouse = yaml.safe_load(
        (ROOT / "charts/thirdparty/clickhouse-ha/values.yaml").read_text()
    )
    keeper = yaml.safe_load(
        (ROOT / "charts/thirdparty/clickhouse-keeper/values.yaml").read_text()
    )
    queue = yaml.safe_load(
        (ROOT / "charts/apps/global-valkey/values-queue.yaml").read_text()
    )
    assert clickhouse["replicaCount"] == 2
    assert keeper["replicaCount"] == 3
    assert clickhouse["nodeSelector"] == keeper["nodeSelector"] == {
        "workload": "infrastructure"
    }
    assert clickhouse["tolerations"] == keeper["tolerations"] == []
    assert tuple(int(part) for part in clickhouse["image"]["tag"].split(".")[:2]) >= (
        25,
        12,
    )
    assert "observability" in queue["networkPolicy"]["allowedNamespaces"]


def test_clickhouse_exposes_langfuse_cluster_and_bootstraps_database() -> None:
    result = subprocess.run(
        [
            "helm",
            "template",
            "clickhouse",
            str(ROOT / "charts/thirdparty/clickhouse-ha"),
            "--namespace",
            "observability",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    items = [item for item in yaml.safe_load_all(result.stdout) if item]
    config = resource(items, "ConfigMap", "clickhouse-config")
    topology = ET.fromstring(config["data"]["cluster.xml"])
    remote_servers = topology.find("remote_servers")
    assert remote_servers is not None
    for cluster_name in ("otel", "default"):
        cluster = remote_servers.find(cluster_name)
        assert cluster is not None
        assert len(cluster.findall("./shard/replica")) == 2

    sql = (
        ROOT
        / "charts/apps/db-schema-bootstrap/schemas/observability/clickhouse/01-database.sql"
    ).read_text()
    assert "CREATE DATABASE IF NOT EXISTS langfuse ON CLUSTER otel;" in sql

    retention_sql = (
        ROOT
        / "charts/apps/db-schema-bootstrap/schemas/observability/clickhouse/09-retention.sql"
    ).read_text()
    assert "-- bootstrap:allow-unknown-table" in retention_sql

    bootstrap_render = subprocess.run(
        [
            "helm",
            "template",
            "observability",
            str(ROOT / "charts/apps/db-schema-bootstrap"),
            "--namespace",
            "observability",
            "--set",
            "app=observability",
            "--set-json",
            "targets=[]",
            "--set",
            "clickhouse.enabled=true",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    bootstrap_items = [
        item for item in yaml.safe_load_all(bootstrap_render.stdout) if item
    ]
    cronjob = resource(
        bootstrap_items, "CronJob", "observability-db-schema-bootstrap-clickhouse"
    )
    command = cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"][
        "containers"
    ][0]["command"][2]
    assert "bootstrap:allow-unknown-table" in command
    assert "Code: 60" in command

    application = documents(
        "argocd/prod/infrastructure/observability-db-schema-bootstrap.yaml"
    )[0]
    values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
    assert values["suspend"] is False
    assert values["clickhouse"]["nodeSelector"] == {"workload": "infrastructure"}
    assert values["clickhouse"]["tolerations"] == []
