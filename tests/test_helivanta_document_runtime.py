import json
import re
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart, *settings):
    command = [
        "helm",
        "template",
        "helivanta-api",
        str(ROOT / chart),
        "-n",
        "helivanta",
    ]
    for setting in settings:
        command.extend(["--set", setting])
    return [
        item
        for item in yaml.safe_load_all(subprocess.check_output(command, text=True))
        if item
    ]


def resource(resources, kind, name):
    return next(
        item
        for item in resources
        if item["kind"] == kind and item["metadata"]["name"] == name
    )


def test_worker_credential_has_an_exact_namespace_bound_reader():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    reader = "read-helivanta-document-worker-production"
    policy = config[f"policy-{reader}.hcl"]
    assert re.findall(r'path "([^"]+)"', policy) == [
        "kv/data/helivanta/production/helivanta-document-worker-db-password"
    ]
    assert re.findall(r"capabilities = \[([^]]+)\]", policy) == ['"read"']
    role = json.loads(config[f"role-{reader}.json"])
    assert role["bound_service_account_names"] == ["helivanta-document-worker"]
    assert role["bound_service_account_namespaces"] == ["helivanta"]
    assert role["token_policies"] == [reader]
    assert role["token_ttl"] == "15m"


def test_login_activation_uses_only_the_worker_secret_and_cannot_inherit():
    resources = render(
        "charts/apps/helivanta-postgres",
        "documentWorker.credentials.enabled=true",
        "documentWorker.login=true",
    )
    cluster = resource(resources, "Cluster", "helivanta-postgres")
    worker = next(
        role
        for role in cluster["spec"]["managed"]["roles"]
        if role["name"] == "helivanta_document_worker"
    )
    assert worker["login"] is True
    assert worker["inherit"] is False
    assert worker["passwordSecret"] == {"name": "helivanta-document-worker-credentials"}
    assert not any(
        worker.get(flag)
        for flag in ["superuser", "bypassrls", "createdb", "createrole", "inRoles"]
    )
    secret = resource(
        resources, "ExternalSecret", "helivanta-document-worker-credentials"
    )["spec"]
    assert secret["secretStoreRef"] == {
        "kind": "SecretStore",
        "name": "openbao-helivanta-document-worker",
    }
    assert secret["target"]["template"]["type"] == "kubernetes.io/basic-auth"
    assert (
        secret["target"]["template"]["metadata"]["labels"]["cnpg.io/reload"] == "true"
    )
    assert (
        secret["target"]["template"]["data"]["username"] == "helivanta_document_worker"
    )
    assert secret["data"] == [
        {
            "secretKey": "password",
            "remoteRef": {
                "key": "helivanta/production/helivanta-document-worker-db-password",
                "property": "password",
            },
        }
    ]
    store = resource(resources, "SecretStore", "openbao-helivanta-document-worker")
    auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
    assert auth["role"] == "read-helivanta-document-worker-production"
    assert auth["serviceAccountRef"] == {"name": "helivanta-document-worker"}


def test_login_refuses_activation_without_credential_projection():
    result = subprocess.run(
        [
            "helm",
            "template",
            "helivanta-postgres",
            str(ROOT / "charts/apps/helivanta-postgres"),
            "--set",
            "documentWorker.login=true",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "worker login requires credential projection" in result.stderr


def test_disabled_documents_do_not_change_running_api_configuration():
    resources = render("charts/apps/helivanta-api")
    assert not any(
        item["metadata"]["name"].startswith(
            ("helivanta-document-worker", "helivanta-clamav")
        )
        for item in resources
    )
    api = resource(resources, "Deployment", "helivanta-api")["spec"]["template"]
    env = api["spec"]["containers"][0]["env"]
    assert not any(
        item["name"]
        in [
            "TEMPORAL_ADDRESS",
            "DOCUMENT_QUARANTINE_BUCKET",
            "DOCUMENT_RELEASED_BUCKET",
        ]
        for item in env
    )


def test_worker_reuses_api_artifact_and_has_only_restricted_credentials():
    resources = render("charts/apps/helivanta-api", "documents.enabled=true")
    api = resource(resources, "Deployment", "helivanta-api")["spec"]["template"]
    deployment = resource(resources, "Deployment", "helivanta-document-worker")
    pod = deployment["spec"]["template"]
    worker = pod["spec"]["containers"][0]
    assert worker["image"] == api["spec"]["containers"][0]["image"]
    assert worker["command"] == ["/app/document-worker"]
    assert pod["spec"]["serviceAccountName"] == "helivanta-document-worker"
    for name in ["helivanta-api", "helivanta-document-worker", "helivanta-clamav"]:
        runtime = resource(resources, "Deployment", name)["spec"]["template"]
        assert runtime["metadata"]["labels"]["sidecar.istio.io/inject"] == "true"
    assert pod["spec"]["terminationGracePeriodSeconds"] >= 120
    assert deployment["spec"]["replicas"] == 2
    env = {item["name"]: item for item in worker["env"]}
    assert env["DOCUMENT_WORKER_DATABASE_URL"]["value"].endswith("?sslmode=require")
    assert env["WORKER_DB_PASSWORD"]["valueFrom"]["secretKeyRef"] == {
        "name": "helivanta-document-worker-credentials",
        "key": "password",
    }
    assert not set(env).intersection(
        [
            "APP_DATABASE_URL",
            "ADMIN_DATABASE_URL",
            "SYSTEM_DATABASE_URL",
            "SESSION_SIGNING_KEY",
            "ZITADEL_LOGIN_CLIENT_TOKEN",
            "NATS_URL",
        ]
    )
    assert "envFrom" not in worker
    assert worker["securityContext"]["readOnlyRootFilesystem"] is True
    assert worker["securityContext"]["allowPrivilegeEscalation"] is False
    assert worker["readinessProbe"]["httpGet"]["path"] == "/readyz"
    assert worker["livenessProbe"]["httpGet"]["path"] == "/healthz"
    assert (
        resource(resources, "PodDisruptionBudget", "helivanta-document-worker")["spec"][
            "minAvailable"
        ]
        == 1
    )
    assert (
        pod["spec"]["topologySpreadConstraints"][0]["topologyKey"]
        == "kubernetes.io/hostname"
    )
    assert env["TEMPORAL_NAMESPACE"]["value"] == "helivanta-documents-prod"
    assert (
        env["CLAMAV_ADDRESS"]["value"]
        == "helivanta-clamav.helivanta.svc.cluster.local:3310"
    )


def test_processing_runtime_can_be_readied_before_accepting_uploads():
    resources = render("charts/apps/helivanta-api", "documents.enabled=true")
    resource(resources, "Deployment", "helivanta-document-worker")
    resource(resources, "Deployment", "helivanta-clamav")
    api = resource(resources, "Deployment", "helivanta-api")
    env = api["spec"]["template"]["spec"]["containers"][0]["env"]
    assert not any(item["name"].startswith("DOCUMENT_") for item in env)

    active = render(
        "charts/apps/helivanta-api",
        "documents.enabled=true",
        "documents.acceptUploads=true",
    )
    api = resource(active, "Deployment", "helivanta-api")
    env = {
        item["name"]: item.get("value")
        for item in api["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    assert (
        env["DOCUMENT_QUARANTINE_BUCKET"]
        == "tesseracthub-480811-helivanta-prod-quarantine"
    )
    assert (
        env["DOCUMENT_RELEASED_BUCKET"] == "tesseracthub-480811-helivanta-prod-released"
    )
    assert env["TEMPORAL_NAMESPACE"] == "helivanta-documents-prod"


def test_upload_acceptance_requires_the_processing_runtime():
    result = subprocess.run(
        [
            "helm",
            "template",
            "helivanta-api",
            str(ROOT / "charts/apps/helivanta-api"),
            "--set",
            "documents.acceptUploads=true",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "upload acceptance requires document processing" in result.stderr


def test_production_activation_uses_the_dedicated_worker_identity():
    applications = ROOT / "argocd/prod/apps/helivanta"
    api = yaml.safe_load((applications / "helivanta-api.yaml").read_text())
    settings = api["spec"]["source"]["helm"].get("valuesObject", {})
    assert settings.get("documents", {}).get("enabled") is True
    assert isinstance(settings["documents"]["acceptUploads"], bool)
    postgres = yaml.safe_load((applications / "helivanta-postgres.yaml").read_text())
    settings = postgres["spec"]["source"]["helm"]["valuesObject"]
    assert settings["instances"] == 2
    assert settings["documentWorker"]["credentials"]["enabled"] is True
    assert settings["documentWorker"]["login"] is True


def test_scanner_is_private_bounded_nonroot_and_definition_storage_is_disposable():
    resources = render("charts/apps/helivanta-api", "documents.enabled=true")
    pod = resource(resources, "Deployment", "helivanta-clamav")["spec"]["template"][
        "spec"
    ]
    container = pod["containers"][0]
    assert "@sha256:" in container["image"]
    assert container["image"].startswith(
        "asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/third-party/clamav:"
    )
    manifest = yaml.safe_load((ROOT / "image-mirror/images.yaml").read_text())
    mirror = next(entry for entry in manifest["images"] if entry["name"] == "clamav")
    assert mirror["source"] == "clamav/clamav"
    assert mirror["mode"] == "tag"
    assert mirror["tag"] == "1.5.4_base"
    assert container["securityContext"]["runAsNonRoot"] is True
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    assert pod["automountServiceAccountToken"] is False
    assert all(
        "secret" not in volume and "persistentVolumeClaim" not in volume
        for volume in pod["volumes"]
    )
    service = resource(resources, "Service", "helivanta-clamav")["spec"]
    assert service["type"] == "ClusterIP"
    assert service["ports"][0]["port"] == 3310
    config = resource(resources, "ConfigMap", "helivanta-clamav")["data"]["clamd.conf"]
    for line in [
        "StreamMaxLength 10M",
        "MaxScanSize 30M",
        "MaxFileSize 10M",
        "MaxRecursion 8",
        "AlertExceedsMax yes",
        "AlertEncryptedArchive yes",
        "AlertEncryptedDoc yes",
        "MaxThreads 4",
        "LogClean no",
        "LogVerbose no",
    ]:
        assert line in config
    assert (
        container["startupProbe"]["failureThreshold"]
        * container["startupProbe"]["periodSeconds"]
        >= 600
    )


def test_mesh_requires_worker_identity_for_scanner_and_only_frontend_for_temporal():
    resources = render("charts/apps/helivanta-api", "documents.enabled=true")
    policy = resource(resources, "AuthorizationPolicy", "helivanta-clamav")["spec"]
    assert policy["action"] == "ALLOW"
    assert policy["rules"] == [
        {
            "from": [
                {
                    "source": {
                        "principals": [
                            "cluster.local/ns/helivanta/sa/helivanta-document-worker"
                        ]
                    }
                }
            ],
            "to": [{"operation": {"ports": ["3310"]}}],
        }
    ]
    assert (
        resource(resources, "PeerAuthentication", "helivanta-clamav")["spec"]["mtls"][
            "mode"
        ]
        == "STRICT"
    )
    platform = render("charts/apps/temporal-platform-resources")
    temporal = resource(platform, "AuthorizationPolicy", "temporal-platform")["spec"][
        "rules"
    ]
    for account in ["helivanta-api", "helivanta-document-worker"]:
        rules = [
            rule
            for rule in temporal
            if any(
                f"cluster.local/ns/helivanta/sa/{account}"
                in source["source"].get("principals", [])
                for source in rule.get("from", [])
            )
        ]
        assert len(rules) == 1
        assert rules[0]["to"] == [{"operation": {"ports": ["7233"]}}]


def test_existing_broad_ingress_cannot_bypass_private_scanner_policy():
    resources = render("charts/apps/helivanta-network-policies")
    for name in ["allow-intra-namespace", "allow-istio-ingress"]:
        selector = resource(resources, "NetworkPolicy", name)["spec"]["podSelector"]
        assert {
            "key": "app.kubernetes.io/name",
            "operator": "NotIn",
            "values": ["helivanta-clamav", "helivanta-document-worker"],
        } in selector["matchExpressions"]
    scanner = resource(
        render("charts/apps/helivanta-api", "documents.enabled=true"),
        "NetworkPolicy",
        "helivanta-clamav",
    )["spec"]
    assert scanner["podSelector"] == {
        "matchLabels": {"app.kubernetes.io/name": "helivanta-clamav"}
    }
    assert scanner["ingress"][0] == {
        "from": [
            {
                "podSelector": {
                    "matchLabels": {
                        "app.kubernetes.io/name": "helivanta-document-worker"
                    }
                }
            }
        ],
        "ports": [{"protocol": "TCP", "port": 3310}],
    }


def test_quota_covers_sidecars_migration_and_concurrent_rollout_surges():
    quota = resource(
        render("charts/apps/helivanta-resource-quota"),
        "ResourceQuota",
        "helivanta-compute",
    )["spec"]["hard"]
    assert int(quota["limits.cpu"]) >= 12
    assert int(quota["limits.memory"].removesuffix("Gi")) >= 16


def test_document_outage_alerts_have_owner_and_recovery_runbook():
    alerts = resource(
        render("charts/apps/helivanta-api", "documents.enabled=true"),
        "PrometheusRule",
        "helivanta-document-processing",
    )["spec"]["groups"][0]["rules"]
    assert {alert["alert"] for alert in alerts} == {
        "HelivantaDocumentWorkerUnavailable",
        "HelivantaDocumentScannerUnavailable",
        "HelivantaDocumentWorkerRestarting",
    }
    for alert in alerts:
        assert alert["labels"]["owner"] == "helivanta"
        assert alert["annotations"]["runbook_url"].endswith(
            "docs/runbooks/helivanta-document-processing.md"
        )
        assert 'namespace="helivanta"' in alert["expr"]
