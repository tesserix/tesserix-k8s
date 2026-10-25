import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart, *overrides):
    args = ["helm", "template", "helivanta", str(ROOT / chart)]
    for value in overrides:
        args.extend(["--set", value])
    return [
        row
        for row in yaml.safe_load_all(subprocess.check_output(args, text=True))
        if row
    ]


def resource(rows, kind, name):
    return next(
        row for row in rows if row["kind"] == kind and row["metadata"]["name"] == name
    )


def test_privacy_role_exists_without_login_or_privileged_membership():
    cluster = resource(
        render("charts/apps/helivanta-postgres"), "Cluster", "helivanta-postgres"
    )
    role = next(
        row
        for row in cluster["spec"]["managed"]["roles"]
        if row["name"] == "helivanta_privacy_worker"
    )
    assert role["inherit"] is False
    assert role["connectionLimit"] == 16
    for flag in ["login", "superuser", "bypassrls", "createdb", "createrole"]:
        assert not role.get(flag, False)
    assert not role.get("inRoles")
    assert not role.get("passwordSecret")


def test_privacy_credential_is_scoped_to_openbao_and_never_shared_with_api():
    rows = render(
        "charts/apps/helivanta-postgres",
        "privacyWorker.credentials.enabled=true",
        "privacyWorker.login=true",
    )
    secret = resource(rows, "ExternalSecret", "helivanta-privacy-worker-credentials")
    assert secret["spec"]["data"] == [
        {
            "secretKey": "password",
            "remoteRef": {
                "key": "helivanta/production/helivanta-privacy-worker-db-password",
                "property": "password",
            },
        }
    ]
    assert (
        secret["spec"]["target"]["template"]["data"]["username"]
        == "helivanta_privacy_worker"
    )
    store = resource(rows, "SecretStore", "openbao-helivanta-privacy-worker")
    auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
    assert auth["role"] == "read-helivanta-privacy-worker-production"
    assert auth["serviceAccountRef"]["name"] == "helivanta-privacy-worker"
    service_account = resource(rows, "ServiceAccount", "helivanta-privacy-worker")
    assert service_account["automountServiceAccountToken"] is False


def test_privacy_worker_openbao_roles_cannot_access_other_product_credentials():
    values = yaml.safe_load(
        (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
    )
    policies = {row["name"]: row["hcl"] for row in values["bootstrap"]["policies"]}
    read = policies["read-helivanta-privacy-worker-production"]
    assert read.count('path "') == 1
    assert "kv/data/helivanta/production/helivanta-privacy-worker-db-password" in read
    assert 'capabilities = ["read"]' in read
    assert "*" not in read
    seed = policies["seed-helivanta-privacy-worker-production"]
    assert 'capabilities = ["create"]' in seed
    assert '"delete"' not in seed
    roles = {row["name"]: row for row in values["bootstrap"]["kubernetesRoles"]}
    reader = roles["read-helivanta-privacy-worker-production"]
    assert reader["serviceAccounts"] == ["helivanta-privacy-worker"]
    assert reader["namespaces"] == ["helivanta"]


def test_privacy_worker_uses_its_own_identity_and_only_private_dependencies():
    rows = render("charts/apps/helivanta-api", "privacyDeadlines.enabled=true")
    deployment = resource(rows, "Deployment", "helivanta-privacy-worker")
    assert deployment["spec"]["replicas"] == 2
    assert deployment["spec"]["strategy"]["rollingUpdate"] == {
        "maxUnavailable": 1,
        "maxSurge": 0,
    }
    pod = deployment["spec"]["template"]["spec"]
    assert pod["serviceAccountName"] == "helivanta-privacy-worker"
    assert pod["automountServiceAccountToken"] is False
    container = pod["containers"][0]
    assert container["command"] == ["/app/privacy-worker"]
    assert "cpu" not in container["resources"]["requests"]
    assert "cpu" not in container["resources"]["limits"]
    env = {row["name"]: row for row in container["env"]}
    assert (
        "sslmode=verify-full&sslrootcert=/etc/postgres-ca/ca.crt"
        in env["PRIVACY_WORKER_DATABASE_URL"]["value"]
    )
    assert not {
        "APP_DATABASE_URL",
        "ADMIN_DATABASE_URL",
        "SYSTEM_DATABASE_URL",
        "EMERGENCY_WORKER_DATABASE_URL",
    }.intersection(env)
    assert container["readinessProbe"]["httpGet"]["path"] == "/readyz"
    assert container["livenessProbe"]["httpGet"]["path"] == "/healthz"
    assert (
        resource(rows, "PodDisruptionBudget", "helivanta-privacy-worker")["spec"][
            "minAvailable"
        ]
        == 1
    )
    network = resource(rows, "NetworkPolicy", "helivanta-privacy-worker")["spec"]
    assert network["ingress"] == []
    assert {port["port"] for rule in network["egress"] for port in rule["ports"]} == {
        53,
        5432,
        7233,
        15012,
    }
    assert not any(
        row["kind"] in {"Service", "Ingress"}
        and row["metadata"]["name"] == "helivanta-privacy-worker"
        for row in rows
    )


def test_broad_namespace_policies_do_not_override_worker_isolation():
    rows = render("charts/apps/helivanta-network-policies")
    for name in [
        "allow-intra-namespace",
        "allow-egress-external",
        "allow-istio-ingress",
        "allow-hbone-15008",
    ]:
        policy = resource(rows, "NetworkPolicy", name)
        expressions = policy["spec"]["podSelector"]["matchExpressions"]
        excluded = {
            value
            for item in expressions
            if item["operator"] == "NotIn"
            for value in item["values"]
        }
        assert "helivanta-privacy-worker" in excluded
        assert "helivanta-privacy-secret-seed" in excluded


def test_privacy_workflows_can_start_without_document_or_emergency_features():
    rows = render(
        "charts/apps/helivanta-api",
        "privacyDeadlines.enabled=true",
        "documents.enabled=false",
        "emergencyDispatch.enabled=false",
    )
    api = resource(rows, "Deployment", "helivanta-api")
    env = {
        row["name"]: row.get("value")
        for row in api["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    assert env["PRIVACY_DEADLINES_ENABLED"] == "true"
    assert (
        env["TEMPORAL_ADDRESS"]
        == "temporal-frontend.temporal-system.svc.cluster.local:7233"
    )
    assert env["TEMPORAL_NAMESPACE"] == "helivanta-documents-prod"


def test_privacy_initializer_is_private_bounded_and_create_only():
    rows = render("charts/apps/helivanta-postgres", "privacyWorker.seed.enabled=true")
    job = next(
        row
        for row in rows
        if row["kind"] == "Job"
        and row["metadata"]["name"].startswith("helivanta-privacy-secret-seed-")
    )
    assert job["spec"]["activeDeadlineSeconds"] == 300
    pod = job["spec"]["template"]["spec"]
    assert pod["serviceAccountName"] == "helivanta-privacy-secret-seed"
    assert pod["automountServiceAccountToken"] is False
    container = pod["containers"][0]
    env = {item["name"]: item["value"] for item in container["env"]}
    assert env == {"WORKER_PRODUCT": "privacy"}
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    script = resource(rows, "ConfigMap", "helivanta-privacy-secret-seed")["data"][
        "seed.py"
    ]
    assert '"cas": 0' in script
    network = resource(rows, "NetworkPolicy", "helivanta-privacy-secret-seed")["spec"]
    assert network["ingress"] == []
    assert {port["port"] for rule in network["egress"] for port in rule["ports"]} == {
        53,
        8200,
        15008,
        15012,
    }


def test_privacy_initializer_preserves_existing_secret_and_scopes_new_secret(
    monkeypatch,
):
    import runpy
    import urllib.error

    monkeypatch.setenv("WORKER_PRODUCT", "privacy")
    module = runpy.run_path(
        str(ROOT / "charts/apps/helivanta-postgres/files/emergency-seed.py")
    )
    assert module["ROLE"] == "seed-helivanta-privacy-worker-production"
    assert (
        module["DATA"]
        == "kv/data/helivanta/production/helivanta-privacy-worker-db-password"
    )

    class Existing:
        def call(self, path, data=None):
            assert path == module["METADATA"]
            assert data is None
            return {
                "data": {
                    "current_version": 2,
                    "versions": {"2": {"destroyed": False, "deletion_time": ""}},
                }
            }

    module["initialize"](Existing())
    writes = []

    class Missing:
        def call(self, path, data=None):
            if data is None:
                assert path == module["METADATA"]
                raise urllib.error.HTTPError(path, 404, "missing", {}, None)
            assert path == module["DATA"]
            writes.append(data)
            return {}

    module["initialize"](Missing())
    assert len(writes) == 1
    assert writes[0]["options"] == {"cas": 0}
    assert len(writes[0]["data"]["password"]) == 64
