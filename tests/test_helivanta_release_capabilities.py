import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def rendered(enabled=True):
    result = subprocess.run(
        [
            "helm",
            "template",
            "helivanta-api",
            "charts/apps/helivanta-api",
            "--namespace",
            "helivanta",
            "--set",
            f"releaseCapabilities.enabled={str(enabled).lower()}",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def test_reader_is_private_mounted_and_delivered_by_a_namespace_bound_identity():
    docs = rendered()
    deployment = next(doc for doc in docs if doc["kind"] == "Deployment")
    pod = deployment["spec"]["template"]["spec"]
    api = next(
        container for container in pod["containers"] if container["name"] == "api"
    )
    env = {row["name"]: row for row in api["env"]}
    assert (
        env["GROWTHBOOK_API_URL"]["value"]
        == "http://growthbook.growthbook.svc.cluster.local:3100"
    )
    assert (
        env["GROWTHBOOK_SDK_KEY_FILE"]["value"] == "/var/run/growthbook/sdk-client-key"
    )
    assert "GROWTHBOOK_SDK_KEY" not in env
    mount = next(
        row for row in api["volumeMounts"] if row["name"] == "release-capabilities"
    )
    assert mount["readOnly"] is True
    volume = next(row for row in pod["volumes"] if row["name"] == mount["name"])
    assert volume["secret"]["secretName"] == "helivanta-growthbook-sdk-key"
    secret = next(
        doc
        for doc in docs
        if doc["kind"] == "ExternalSecret"
        and doc["metadata"]["name"] == "helivanta-growthbook-sdk-key"
    )
    assert secret["spec"]["data"] == [
        {
            "secretKey": "sdk-client-key",
            "remoteRef": {
                "key": "helivanta/prod/app/helivanta-growthbook-sdk-key",
                "property": "value",
            },
        }
    ]
    store = next(
        doc
        for doc in docs
        if doc["kind"] == "SecretStore"
        and doc["metadata"]["name"] == "helivanta-growthbook-reader"
    )
    auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
    assert auth["role"] == "helivanta-growthbook-reader"
    assert auth["serviceAccountRef"]["name"] == "helivanta-api"


def test_disabled_chart_adds_no_optional_provider_dependency():
    deployment = next(doc for doc in rendered(False) if doc["kind"] == "Deployment")
    api = deployment["spec"]["template"]["spec"]["containers"][0]
    assert not any(row["name"].startswith("GROWTHBOOK_") for row in api["env"])


def test_provider_egress_targets_only_the_shared_provider_port_and_namespace():
    policy = next(
        doc
        for doc in rendered()
        if doc["kind"] == "NetworkPolicy"
        and doc["metadata"]["name"] == "helivanta-api-growthbook"
    )
    assert policy["spec"]["policyTypes"] == ["Egress"]
    assert policy["spec"]["egress"] == [
        {
            "to": [
                {
                    "namespaceSelector": {
                        "matchLabels": {"kubernetes.io/metadata.name": "growthbook"}
                    },
                    "podSelector": {
                        "matchLabels": {"app.kubernetes.io/name": "growthbook"}
                    },
                }
            ],
            "ports": [{"protocol": "TCP", "port": 3100}],
        }
    ]


def test_openbao_reader_cannot_write_or_read_another_product():
    values = yaml.safe_load(
        (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
    )
    bootstrap = values["bootstrap"]
    policy = next(
        row
        for row in bootstrap["policies"]
        if row["name"] == "helivanta-growthbook-reader"
    )
    assert (
        policy["hcl"].strip()
        == 'path "kv/data/helivanta/prod/app/helivanta-growthbook-sdk-key" { capabilities = ["read"] }'
    )
    role = next(
        row
        for row in bootstrap["kubernetesRoles"]
        if row["name"] == "helivanta-growthbook-reader"
    )
    assert role["serviceAccounts"] == ["helivanta-api"]
    assert role["namespaces"] == ["helivanta"]
    assert role["policies"] == ["helivanta-growthbook-reader"]


def test_provider_seed_uses_the_pinned_provider_image_and_mounted_credentials():
    result = subprocess.run(
        [
            "helm",
            "template",
            "growthbook",
            "charts/thirdparty/growthbook",
            "--namespace",
            "growthbook",
            "--set",
            "helivantaRelease.enabled=true",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    docs = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
    job = next(
        doc
        for doc in docs
        if doc["kind"] == "Job"
        and doc["metadata"]["name"] == "growthbook-helivanta-release"
    )
    spec = job["spec"]["template"]["spec"]
    assert spec["automountServiceAccountToken"] is False
    assert spec["serviceAccountName"] == "helivanta-growthbook-seed"
    container = spec["containers"][0]
    assert "@sha256:" in container["image"] and ":latest" not in container["image"]
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    assert container["command"] == ["node", "/config/helivanta-release.mjs", "--run"]
    assert "env" not in container
    volumes = {volume["name"]: volume for volume in spec["volumes"]}
    assert volumes["admin"]["secret"]["secretName"] == "growthbook-admin-secret"
    assert volumes["bao"]["projected"]["sources"] == [
        {"serviceAccountToken": {"path": "token", "expirationSeconds": 600}}
    ]


def test_only_the_requested_owner_and_pharmacy_foundation_is_enabled():
    import json

    config = json.loads(
        (ROOT / "charts/thirdparty/growthbook/files/helivanta-release.json").read_text()
    )
    assert {key for key, enabled in config["flags"].items() if enabled} == {
        "helivanta.release.onboarding",
        "helivanta.release.team_accounts",
        "helivanta.release.staff_core",
        "helivanta.release.department_teams",
        "helivanta.release.pharmacy_setup",
        "helivanta.release.pharmacy_staff",
    }
    assert all(type(value) is bool for value in config["flags"].values())
    assert config["flags"]["helivanta.release.pharmacy_counter"] is False
    assert config["flags"]["helivanta.release.supplier_collaboration"] is False


def test_seed_writer_can_create_but_cannot_rotate_existing_credentials():
    values = yaml.safe_load(
        (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
    )["bootstrap"]
    policy = next(
        row
        for row in values["policies"]
        if row["name"] == "helivanta-growthbook-writer"
    )["hcl"]
    assert (
        'path "kv/data/helivanta/prod/app/helivanta-growthbook-sdk-key" { capabilities = ["create", "read"] }'
        in policy
    )
    assert 'capabilities = ["create", "read", "update"]' not in policy
    assert "kv/data/*" not in policy
    role = next(
        row
        for row in values["kubernetesRoles"]
        if row["name"] == "helivanta-growthbook-writer"
    )
    assert role["namespaces"] == ["growthbook"]
    assert role["serviceAccounts"] == ["helivanta-growthbook-seed"]
