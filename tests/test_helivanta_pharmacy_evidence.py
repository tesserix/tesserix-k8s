import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart, *settings):
    command = ["helm", "template", "pharmacy-test", str(ROOT / chart), "-n", "helivanta"]
    for setting in settings:
        command.extend(["--set", setting])
    return [item for item in yaml.safe_load_all(subprocess.check_output(command, text=True)) if item]


def resource(items, kind, name):
    matches = [item for item in items if item["kind"] == kind and item["metadata"]["name"] == name]
    assert len(matches) == 1, (kind, name, len(matches))
    return matches[0]


ENABLED = ("pharmacyEvidence.enabled=true", "documents.enabled=true", "documents.acceptUploads=true")


def test_default_worker_is_dormant_and_role_has_no_authority_expansion():
    database = render("charts/apps/helivanta-postgres")
    role = next(r for r in resource(database, "Cluster", "helivanta-postgres")["spec"]["managed"]["roles"] if r["name"] == "helivanta_pharmacy_evidence_worker")
    assert role["ensure"] == "present"
    for attribute in ["login", "inherit", "superuser", "bypassrls", "createdb", "createrole", "inRoles", "passwordSecret"]:
        assert not role.get(attribute), attribute
    assert not resource(database, "ServiceAccount", "helivanta-pharmacy-evidence-worker")["automountServiceAccountToken"]
    assert not any(r["kind"] == "Deployment" and r["metadata"]["name"] == "helivanta-pharmacy-evidence-worker" for r in render("charts/apps/helivanta-api"))


def test_worker_has_only_its_own_runtime_credential_and_same_promoted_artifact():
    rendered = render("charts/apps/helivanta-api", *ENABLED)
    deployment = resource(rendered, "Deployment", "helivanta-pharmacy-evidence-worker")
    assert deployment["spec"]["replicas"] == 2
    pod = deployment["spec"]["template"]["spec"]
    assert pod["serviceAccountName"] == "helivanta-pharmacy-evidence-worker"
    worker = pod["containers"][0]
    assert worker["command"] == ["/app/pharmacy-evidence-worker"]
    api = resource(rendered, "Deployment", "helivanta-api")["spec"]["template"]["spec"]["containers"][0]
    assert worker["image"] == api["image"]
    environment = {item["name"]: item for item in worker["env"]}
    assert "PHARMACY_EVIDENCE_WORKER_DATABASE_URL" in environment
    assert not set(environment) & {"DATABASE_URL", "ADMIN_DATABASE_URL", "SYSTEM_DATABASE_URL", "DOCUMENT_WORKER_DATABASE_URL", "SUPPLY_EVIDENCE_WORKER_DATABASE_URL", "NATS_URL", "SESSION_SIGNING_KEY"}
    assert environment["WORKER_DB_PASSWORD"]["valueFrom"]["secretKeyRef"]["name"] == "helivanta-pharmacy-evidence-worker-credentials"
    assert worker["securityContext"]["readOnlyRootFilesystem"]
    assert worker["readinessProbe"]["httpGet"]["path"] == "/readyz"
    assert next(e for e in api["env"] if e["name"] == "PHARMACY_EVIDENCE_ENABLED")["value"] == "true"
    resource(rendered, "PodDisruptionBudget", "helivanta-pharmacy-evidence-worker")


@pytest.mark.parametrize("settings", [("pharmacyEvidence.enabled=true",), ("pharmacyEvidence.enabled=true", "documents.enabled=true"), ("pharmacyEvidenceWorker.login=true",)])
def test_activation_requires_private_processing_and_separate_credential(settings):
    chart = "charts/apps/helivanta-postgres" if settings[0].startswith("pharmacyEvidenceWorker") else "charts/apps/helivanta-api"
    with pytest.raises(subprocess.CalledProcessError):
        render(chart, *settings)


def test_exact_credential_reader_and_non_inheriting_login():
    rendered = render("charts/apps/helivanta-postgres", "pharmacyEvidenceWorker.login=true", "pharmacyEvidenceWorker.credentials.enabled=true")
    role = next(r for r in resource(rendered, "Cluster", "helivanta-postgres")["spec"]["managed"]["roles"] if r["name"] == "helivanta_pharmacy_evidence_worker")
    assert role["login"] and not role["inherit"]
    assert role["passwordSecret"]["name"] == "helivanta-pharmacy-evidence-worker-credentials"
    secret = resource(rendered, "ExternalSecret", "helivanta-pharmacy-evidence-worker-credentials")
    assert secret["spec"]["data"] == [{"secretKey": "password", "remoteRef": {"key": "helivanta/production/helivanta-pharmacy-evidence-worker-db-password", "property": "password"}}]
    store = resource(rendered, "SecretStore", "openbao-helivanta-pharmacy-evidence-worker")
    authentication = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
    assert authentication["role"] == "read-helivanta-pharmacy-evidence-worker-production"
    assert authentication["serviceAccountRef"]["name"] == "helivanta-pharmacy-evidence-worker"


def test_worker_is_separately_admitted_to_scanner_and_has_no_nats_egress():
    rendered = render("charts/apps/helivanta-api", *ENABLED)
    network = resource(rendered, "NetworkPolicy", "helivanta-pharmacy-evidence-worker")
    ports = {p["port"] for rule in network["spec"]["egress"] for p in rule["ports"]}
    assert ports == {5432, 3310, 443}
    # Temporal, mesh and GKE workload identity each have a separate narrow policy.
    for name, expected_ports in [("helivanta-documents-temporal", {7233}), ("helivanta-documents-istiod", {15012}), ("helivanta-documents-workload-identity", {80, 988})]:
        policy = resource(rendered, "NetworkPolicy", name)
        selectors = policy["spec"]["podSelector"]["matchExpressions"]
        assert any(item["key"] == "app.kubernetes.io/name" and item["operator"] == "In" and item["values"].count("helivanta-pharmacy-evidence-worker") == 1 for item in selectors)
        assert {port["port"] for rule in policy["spec"]["egress"] for port in rule["ports"]} == expected_ports
    scanner = resource(rendered, "AuthorizationPolicy", "helivanta-clamav")
    principals = scanner["spec"]["rules"][0]["from"][0]["source"]["principals"]
    assert principals.count("cluster.local/ns/helivanta/sa/helivanta-pharmacy-evidence-worker") == 1
    scanner_network = resource(rendered, "NetworkPolicy", "helivanta-clamav")
    allowed = [source.get("podSelector", {}).get("matchLabels", {}).get("app.kubernetes.io/name") for rule in scanner_network["spec"]["ingress"] for source in rule["from"]]
    assert allowed.count("helivanta-pharmacy-evidence-worker") == 1


def test_openbao_reader_has_one_exact_path_identity_and_short_lifetime():
    values = yaml.safe_load((ROOT / "charts/thirdparty/openbao/values.yaml").read_text())
    name = "read-helivanta-pharmacy-evidence-worker-production"
    policies = [p for p in values["bootstrap"]["policies"] if p["name"] == name]
    assert len(policies) == 1
    assert policies[0]["hcl"].strip() == 'path "kv/data/helivanta/production/helivanta-pharmacy-evidence-worker-db-password" { capabilities = ["read"] }'
    roles = [r for r in values["bootstrap"]["kubernetesRoles"] if r["name"] == name]
    assert roles == [{"name": name, "serviceAccounts": ["helivanta-pharmacy-evidence-worker"], "namespaces": ["helivanta"], "policies": [name], "ttl": "15m"}]
