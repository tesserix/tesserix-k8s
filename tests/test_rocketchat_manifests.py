import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def render():
    result = subprocess.run(
        [
            "helm",
            "template",
            "rocketchat",
            str(ROOT / "charts/thirdparty/rocketchat"),
            "--namespace",
            "rocketchat",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def test_only_named_members_can_provision_through_zitadel():
    docs = render()
    project = next(d for d in docs if d["kind"] == "ZitadelProject")
    assert project["spec"]["access"] == {
        "mode": "restricted",
        "members": [
            {"email": "samyak.rout@gmail.com", "roles": ["admin"]},
            {"email": "mahesh.sangawar@gmail.com", "roles": ["admin"]},
        ],
    }
    deploy = next(d for d in docs if d["kind"] == "Deployment")
    env = {
        v["name"]: v.get("value")
        for v in deploy["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    for setting in [
        "Accounts_AllowAnonymousRead",
        "Accounts_AllowAnonymousWrite",
        "Accounts_PasswordReset",
        "Accounts_AllowPasswordChange",
        "Accounts_AllowPasswordChangeForOAuthUsers",
        "Accounts_AllowEmailChange",
    ]:
        assert env[f"OVERWRITE_SETTING_{setting}"] == "false"
    assert env["OVERWRITE_SETTING_Accounts_RegistrationForm"] == "Disabled"
    assert (
        env["OVERWRITE_SETTING_Accounts_Registration_AuthenticationServices_Enabled"]
        == "true"
    )
    assert env["Accounts_OAuth_Custom_Zitadel_key_field"] == "sub"
    assert env["Accounts_OAuth_Custom_Zitadel_merge_users"] == "false"


def test_database_is_authenticated_replicated_and_storage_retained():
    docs = render()
    db = next(d for d in docs if d["kind"] == "StatefulSet")
    assert db["spec"]["replicas"] == 3
    assert db["spec"]["podManagementPolicy"] == "Parallel"
    container = db["spec"]["template"]["spec"]["containers"][0]
    assert "--replSet" in container["args"]
    assert "--keyFile" in container["args"]
    assert "--auth" in container["args"]
    assert "@sha256:" in container["image"]
    assert db["spec"]["persistentVolumeClaimRetentionPolicy"] == {
        "whenDeleted": "Retain",
        "whenScaled": "Retain",
    }
    assert (
        db["spec"]["volumeClaimTemplates"][0]["spec"]["storageClassName"]
        == "standard-rwo-retain"
    )
    assert (
        next(d for d in docs if d["kind"] == "PodDisruptionBudget")["spec"][
            "minAvailable"
        ]
        == 2
    )


def test_database_ports_are_not_public_and_secrets_are_scoped():
    docs = render()
    service = next(
        d
        for d in docs
        if d["kind"] == "Service" and d["metadata"]["name"] == "rocketchat-mongodb"
    )
    assert service["spec"]["clusterIP"] == "None"
    policies = [d for d in docs if d["kind"] == "NetworkPolicy"]
    assert any(
        d["spec"]["podSelector"] == {} and d["spec"]["ingress"] == [] for d in policies
    )
    store = next(d for d in docs if d["kind"] == "SecretStore")
    auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
    assert auth["role"] == "read-rocketchat-production"
    secrets = [d for d in docs if d["kind"] == "ExternalSecret"]
    assert len(secrets) == 2
    for secret in secrets:
        assert secret["spec"]["refreshInterval"] == "1m"
        for item in secret["spec"]["data"]:
            assert item["remoteRef"]["key"].startswith(
                "rocketchat/prod/app/rocketchat-"
            )
    route = next(d for d in docs if d["kind"] == "VirtualService")
    assert route["spec"]["hosts"] == ["rocketchat.tesserix.app"]
    assert "timeout" not in route["spec"]["http"][0]


def test_openbao_role_cannot_read_other_products():
    config = yaml.safe_load(
        (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
    )["bootstrap"]
    role = next(
        r
        for r in config["kubernetesRoles"]
        if r["name"] == "read-rocketchat-production"
    )
    assert role["namespaces"] == ["rocketchat"]
    assert role["serviceAccounts"] == ["rocketchat-production-reader"]
    policy = next(
        p for p in config["policies"] if p["name"] == "read-rocketchat-production"
    )
    assert "*" not in policy["hcl"]
    assert policy["hcl"].count('capabilities = ["read"]') == 6


def test_bootstrap_writer_is_bound_to_platform_bootstrap_identity():
    config = yaml.safe_load(
        (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
    )["bootstrap"]
    role = next(
        r
        for r in config["kubernetesRoles"]
        if r["name"] == "seed-rocketchat-production"
    )
    assert role["namespaces"] == ["openbao"]
    assert role["serviceAccounts"] == ["openbao-bootstrap"]
    assert role["ttl"] == "15m"
    policy = next(
        p for p in config["policies"] if p["name"] == "seed-rocketchat-production"
    )
    assert "*" not in policy["hcl"]
    assert policy["hcl"].count('capabilities = ["create", "read", "update"]') == 6
