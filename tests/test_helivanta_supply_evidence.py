import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart: str, *settings: str) -> list[dict]:
    command = [
        "helm",
        "template",
        "evidence-test",
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


def resource(items: list[dict], kind: str, name: str) -> dict:
    return next(
        item
        for item in items
        if item["kind"] == kind and item["metadata"]["name"] == name
    )


def test_supply_identity_is_dormant_without_inherited_or_clinical_access() -> None:
    resources = render("charts/apps/helivanta-postgres")
    roles = resource(resources, "Cluster", "helivanta-postgres")["spec"]["managed"][
        "roles"
    ]
    role = next(
        role for role in roles if role["name"] == "helivanta_supply_evidence_worker"
    )
    assert role["ensure"] == "present"
    assert not role["inherit"]
    assert not any(
        role.get(key)
        for key in [
            "login",
            "superuser",
            "bypassrls",
            "createdb",
            "createrole",
            "inRoles",
            "passwordSecret",
        ]
    )
    assert not resource(
        resources, "ServiceAccount", "helivanta-supply-evidence-worker"
    )["automountServiceAccountToken"]
    assert not any(
        item["kind"] == "Deployment"
        and item["metadata"]["name"] == "helivanta-supply-evidence-worker"
        for item in render("charts/apps/helivanta-api")
    )


def test_supply_worker_uses_its_own_runtime_secret_and_same_release_artifact() -> None:
    resources = render(
        "charts/apps/helivanta-api",
        "documents.enabled=true",
        "supplyEvidence.enabled=true",
    )
    deployment = resource(resources, "Deployment", "helivanta-supply-evidence-worker")
    assert deployment["spec"]["replicas"] == 2
    pod = deployment["spec"]["template"]["spec"]
    assert pod["serviceAccountName"] == "helivanta-supply-evidence-worker"
    worker = pod["containers"][0]
    assert worker["command"] == ["/app/supply-evidence-worker"]
    api = resource(resources, "Deployment", "helivanta-api")["spec"]["template"][
        "spec"
    ]["containers"][0]
    assert worker["image"] == api["image"]
    env = {item["name"]: item for item in worker["env"]}
    assert "SUPPLY_EVIDENCE_WORKER_DATABASE_URL" in env
    assert not any(
        name in env
        for name in [
            "DOCUMENT_WORKER_DATABASE_URL",
            "DATABASE_URL",
            "ADMIN_DATABASE_URL",
            "SYSTEM_DATABASE_URL",
            "SESSION_SIGNING_KEY",
            "NATS_URL",
        ]
    )
    assert (
        env["WORKER_DB_PASSWORD"]["valueFrom"]["secretKeyRef"]["name"]
        == "helivanta-supply-evidence-worker-credentials"
    )
    assert worker["securityContext"]["readOnlyRootFilesystem"]
    assert worker["readinessProbe"]["httpGet"]["path"] == "/readyz"
    assert deployment["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] == 0


def test_supply_activation_requires_storage_and_separate_credential_projection() -> (
    None
):
    for chart, settings in [
        ("helivanta-api", ["supplyEvidence.enabled=true"]),
        ("helivanta-postgres", ["supplyEvidenceWorker.login=true"]),
    ]:
        result = subprocess.run(
            [
                "helm",
                "template",
                "evidence-test",
                str(ROOT / "charts/apps" / chart),
                *[value for setting in settings for value in ["--set", setting]],
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode != 0


def test_supply_credential_reader_is_exact_and_clinical_worker_is_preserved() -> None:
    resources = render(
        "charts/apps/helivanta-postgres",
        "supplyEvidenceWorker.login=true",
        "supplyEvidenceWorker.credentials.enabled=true",
    )
    secret = resource(
        resources, "ExternalSecret", "helivanta-supply-evidence-worker-credentials"
    )
    assert secret["spec"]["data"] == [
        {
            "secretKey": "password",
            "remoteRef": {
                "key": "helivanta/production/helivanta-supply-evidence-worker-db-password",
                "property": "password",
            },
        }
    ]
    store = resource(
        resources, "SecretStore", "openbao-helivanta-supply-evidence-worker"
    )
    auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
    assert auth["role"] == "read-helivanta-supply-evidence-worker-production"
    assert auth["serviceAccountRef"]["name"] == "helivanta-supply-evidence-worker"


def test_production_supply_login_uses_the_separate_secret_without_inheritance() -> None:
    application = yaml.safe_load(
        (ROOT / "argocd/prod/apps/helivanta/helivanta-postgres.yaml").read_text()
    )
    resources = list(
        yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "production-test",
                    str(ROOT / "charts/apps/helivanta-postgres"),
                    "-n",
                    "helivanta",
                    "-f",
                    "-",
                ],
                input=yaml.safe_dump(
                    application["spec"]["source"]["helm"]["valuesObject"]
                ),
                text=True,
            )
        )
    )
    cluster = resource(resources, "Cluster", "helivanta-postgres")
    roles = {role["name"]: role for role in cluster["spec"]["managed"]["roles"]}
    role = roles["helivanta_supply_evidence_worker"]
    assert role["login"] is True
    assert role["inherit"] is False
    assert (
        role["passwordSecret"]["name"] == "helivanta-supply-evidence-worker-credentials"
    )
    assert (
        roles["helivanta_document_worker"]["passwordSecret"]["name"]
        == "helivanta-document-worker-credentials"
    )
    assert cluster["spec"]["instances"] == 2


def test_supply_network_admits_only_the_separate_worker_and_required_ports() -> None:
    resources = render(
        "charts/apps/helivanta-api",
        "documents.enabled=true",
        "supplyEvidence.enabled=true",
    )
    scanner = resource(resources, "AuthorizationPolicy", "helivanta-clamav")["spec"]
    assert scanner["rules"][0]["from"][0]["source"]["principals"] == [
        "cluster.local/ns/helivanta/sa/helivanta-document-worker",
        "cluster.local/ns/helivanta/sa/helivanta-supply-evidence-worker",
    ]
    assert scanner["rules"][0]["to"] == [{"operation": {"ports": ["3310"]}}]
    worker = resource(resources, "NetworkPolicy", "helivanta-supply-evidence-worker")[
        "spec"
    ]
    assert worker["ingress"] == []
    assert {port["port"] for rule in worker["egress"] for port in rule["ports"]} == {
        5432,
        3310,
        443,
    }
    broad = render("charts/apps/helivanta-network-policies")
    for name in [
        "allow-intra-namespace",
        "allow-istio-ingress",
        "allow-egress-external",
    ]:
        expressions = resource(broad, "NetworkPolicy", name)["spec"]["podSelector"][
            "matchExpressions"
        ]
        assert any(
            item["operator"] == "NotIn"
            and "helivanta-supply-evidence-worker" in item["values"]
            for item in expressions
        )
