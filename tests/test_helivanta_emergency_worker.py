import subprocess
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart, *overrides):
    args = ["helm", "template", "helivanta", str(ROOT / chart)]
    for value in overrides:
        args.extend(["--set", value])
    return [
        x for x in yaml.safe_load_all(subprocess.check_output(args, text=True)) if x
    ]


def resource(rows, kind, name):
    return next(x for x in rows if x["kind"] == kind and x["metadata"]["name"] == name)


def test_emergency_role_exists_without_login_or_privileged_membership():
    rows = render("charts/apps/helivanta-postgres")
    cluster = resource(rows, "Cluster", "helivanta-postgres")
    role = next(
        x
        for x in cluster["spec"]["managed"]["roles"]
        if x["name"] == "helivanta_emergency_worker"
    )
    assert role["inherit"] is False
    for flag in ["login", "superuser", "bypassrls", "createdb", "createrole"]:
        assert not role.get(flag, False)
    assert not role.get("inRoles")
    assert not role.get("passwordSecret")


def test_emergency_credential_uses_an_exact_openbao_path_and_bound_identity():
    rows = render(
        "charts/apps/helivanta-postgres",
        "emergencyWorker.credentials.enabled=true",
        "emergencyWorker.login=true",
    )
    secret = resource(rows, "ExternalSecret", "helivanta-emergency-worker-credentials")
    assert secret["spec"]["data"] == [
        {
            "secretKey": "password",
            "remoteRef": {
                "key": "helivanta/production/helivanta-emergency-worker-db-password",
                "property": "password",
            },
        }
    ]
    assert (
        secret["spec"]["target"]["template"]["data"]["username"]
        == "helivanta_emergency_worker"
    )
    store = resource(rows, "SecretStore", "openbao-helivanta-emergency-worker")
    auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
    assert auth["role"] == "read-helivanta-emergency-worker-production"
    assert auth["serviceAccountRef"]["name"] == "helivanta-emergency-worker"


def test_emergency_worker_is_private_and_uses_verified_database_tls_without_surge():
    rows = render(
        "charts/apps/helivanta-api",
        "emergencyDispatch.enabled=true",
        "image.repository=asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/helivanta-api",
    )
    deployment = resource(rows, "Deployment", "helivanta-emergency-worker")
    assert deployment["spec"]["replicas"] == 2
    assert deployment["spec"]["strategy"]["rollingUpdate"] == {
        "maxUnavailable": 1,
        "maxSurge": 0,
    }
    pod = deployment["spec"]["template"]["spec"]
    assert pod["serviceAccountName"] == "helivanta-emergency-worker"
    assert pod["automountServiceAccountToken"] is False
    container = pod["containers"][0]
    assert container["command"] == ["/app/emergency-worker"]
    assert container["image"].startswith("asia-south1-docker.pkg.dev/")
    env = {x["name"]: x for x in container["env"]}
    assert "sslmode=verify-full" in env["EMERGENCY_WORKER_DATABASE_URL"]["value"]
    assert (
        "sslrootcert=/etc/postgres-ca/ca.crt"
        in env["EMERGENCY_WORKER_DATABASE_URL"]["value"]
    )
    assert not {
        "APP_DATABASE_URL",
        "ADMIN_DATABASE_URL",
        "SYSTEM_DATABASE_URL",
        "DOCUMENT_WORKER_DATABASE_URL",
        "OPENBAO_TOKEN",
    }.intersection(env)
    assert container["resources"]["limits"]["cpu"] == "250m"
    ca = next(v for v in pod["volumes"] if v["name"] == "database-ca")
    assert ca["secret"]["items"] == [{"key": "ca.crt", "path": "ca.crt"}]
    assert (
        resource(rows, "PodDisruptionBudget", "helivanta-emergency-worker")["spec"][
            "minAvailable"
        ]
        == 1
    )


def test_worker_remains_disabled_until_the_reviewed_api_artifact_is_ready():
    rows = render("charts/apps/helivanta-api")
    assert not any(
        x["kind"] == "Deployment"
        and x["metadata"]["name"] == "helivanta-emergency-worker"
        for x in rows
    )


def test_emergency_worker_reaches_only_database_dns_mesh_and_existing_temporal():
    rows = render("charts/apps/helivanta-api", "emergencyDispatch.enabled=true")
    net = resource(rows, "NetworkPolicy", "helivanta-emergency-worker")
    assert net["spec"]["policyTypes"] == ["Ingress", "Egress"]
    assert net["spec"]["ingress"] == []
    ports = {p["port"] for rule in net["spec"]["egress"] for p in rule["ports"]}
    assert ports == {53, 5432, 7233, 15012}
    assert not any(
        "ipBlock" in peer for rule in net["spec"]["egress"] for peer in rule["to"]
    )
    worker = resource(rows, "Deployment", "helivanta-emergency-worker")
    env = {
        x["name"]: x.get("value")
        for x in worker["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    assert (
        env["TEMPORAL_ADDRESS"]
        == "temporal-frontend.temporal-system.svc.cluster.local:7233"
    )


def test_api_and_worker_share_temporal_when_document_storage_is_disabled():
    rows = render(
        "charts/apps/helivanta-api",
        "emergencyDispatch.enabled=true",
        "documents.enabled=false",
    )
    api = resource(rows, "Deployment", "helivanta-api")
    env = {
        x["name"]: x.get("value")
        for x in api["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    assert env["EMERGENCY_DISPATCH_ENABLED"] == "true"
    assert (
        env["TEMPORAL_ADDRESS"]
        == "temporal-frontend.temporal-system.svc.cluster.local:7233"
    )
    assert env["TEMPORAL_NAMESPACE"] == "helivanta-documents-prod"
    assert "DOCUMENT_QUARANTINE_BUCKET" not in env


def test_bao_policy_and_temporal_peer_are_narrowly_bound_to_the_worker():
    values = yaml.safe_load(
        (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
    )

    def objects(value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from objects(child)
        elif isinstance(value, list):
            for child in value:
                yield from objects(child)

    matches = [
        x
        for x in objects(values)
        if x.get("name") == "read-helivanta-emergency-worker-production"
    ]
    policy = next(x for x in matches if "hcl" in x)
    assert (
        policy["hcl"].strip()
        == 'path "kv/data/helivanta/production/helivanta-emergency-worker-db-password" { capabilities = ["read"] }'
    )
    role = next(x for x in matches if "serviceAccounts" in x)
    assert role["serviceAccounts"] == ["helivanta-emergency-worker"]
    assert role["namespaces"] == ["helivanta"]
    peers = yaml.safe_load(
        (ROOT / "charts/apps/temporal-platform-resources/values.yaml").read_text()
    )["clients"]
    assert (
        peers.count(
            {"namespace": "helivanta", "serviceAccount": "helivanta-emergency-worker"}
        )
        == 1
    )


def test_emergency_worker_does_not_project_a_kubernetes_or_cloud_credential():
    rows = render(
        "charts/apps/helivanta-postgres", "emergencyWorker.credentials.enabled=true"
    )
    sa = resource(rows, "ServiceAccount", "helivanta-emergency-worker")
    assert sa["automountServiceAccountToken"] is False
    assert "iam.gke.io/gcp-service-account" not in sa["metadata"].get("annotations", {})


def test_suspending_new_reservations_keeps_existing_workflows_running():
    rows = render(
        "charts/apps/helivanta-api",
        "emergencyDispatch.enabled=true",
        "emergencyDispatch.acceptNew=false",
    )
    api = resource(rows, "Deployment", "helivanta-api")
    env = {
        x["name"]: x.get("value")
        for x in api["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    assert env["EMERGENCY_DISPATCH_ENABLED"] == "false"
    assert env["EMERGENCY_WORKFLOWS_ENABLED"] == "true"
    assert (
        resource(rows, "Deployment", "helivanta-emergency-worker")["spec"]["replicas"]
        == 2
    )


def test_secret_seed_is_disabled_by_default_and_has_scoped_short_lived_identity():
    assert not any(
        x["kind"] == "Job"
        and x["metadata"]["name"].startswith("helivanta-emergency-secret-seed")
        for x in render("charts/apps/helivanta-postgres")
    )
    rows = render("charts/apps/helivanta-postgres", "emergencyWorker.seed.enabled=true")
    job = next(
        x
        for x in rows
        if x["kind"] == "Job"
        and x["metadata"]["name"].startswith("helivanta-emergency-secret-seed")
    )
    pod = job["spec"]["template"]["spec"]
    assert pod["serviceAccountName"] == "helivanta-emergency-secret-seed"
    assert pod["automountServiceAccountToken"] is False
    token = next(x for x in pod["volumes"] if x["name"] == "token")
    assert (
        token["projected"]["sources"][0]["serviceAccountToken"]["expirationSeconds"]
        == 600
    )
    assert (
        job["spec"]["template"]["metadata"]["annotations"][
            "sidecar.istio.io/nativeSidecar"
        ]
        == "true"
    )
    assert pod["containers"][0]["image"].startswith("asia-south1-docker.pkg.dev/")
    assert "@sha256:" in pod["containers"][0]["image"]
    assert not pod["containers"][0].get("envFrom")


def test_workers_leave_capacity_for_the_next_migration():
    rows = render("charts/apps/helivanta-api", "emergencyDispatch.enabled=true")
    worker = resource(rows, "Deployment", "helivanta-emergency-worker")
    annotations = worker["spec"]["template"]["metadata"]["annotations"]
    proxy_limit = int(annotations["sidecar.istio.io/proxyCPULimit"].removesuffix("m"))
    limit = int(
        worker["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"][
            "cpu"
        ].removesuffix("m")
    )
    assert 10750 + worker["spec"]["replicas"] * (proxy_limit + limit) + 500 < 12000


def test_production_processes_existing_trips_without_accepting_new_reservations():
    api = yaml.safe_load(
        (ROOT / "argocd/prod/apps/helivanta/helivanta-api.yaml").read_text()
    )
    dispatch = (
        api["spec"]["source"]["helm"]
        .get("valuesObject", {})
        .get("emergencyDispatch", {})
    )
    assert dispatch == {"enabled": True, "acceptNew": False}
    postgres = yaml.safe_load(
        (ROOT / "argocd/prod/apps/helivanta/helivanta-postgres.yaml").read_text()
    )
    worker = postgres["spec"]["source"]["helm"]["valuesObject"]["emergencyWorker"]
    assert worker == {
        "seed": {"enabled": True},
        "credentials": {"enabled": True},
        "login": True,
    }


def test_seed_proxy_memory_is_sufficient_and_changes_create_a_new_job():
    rows = render("charts/apps/helivanta-postgres", "emergencyWorker.seed.enabled=true")
    job = next(
        r
        for r in rows
        if r["kind"] == "Job"
        and r["metadata"]["name"].startswith("helivanta-emergency-secret-seed")
    )
    assert (
        job["spec"]["template"]["metadata"]["annotations"][
            "sidecar.istio.io/proxyMemoryLimit"
        ]
        == "256Mi"
    )
    changed = render(
        "charts/apps/helivanta-postgres",
        "emergencyWorker.seed.enabled=true",
        "emergencyWorker.seed.proxyMemoryLimit=384Mi",
    )
    new_job = next(
        r
        for r in changed
        if r["kind"] == "Job"
        and r["metadata"]["name"].startswith("helivanta-emergency-secret-seed")
    )
    assert new_job["metadata"]["name"] != job["metadata"]["name"]
