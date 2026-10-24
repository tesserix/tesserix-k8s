import re
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_email_state_uses_authenticated_non_evicting_valkey():
    app = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/zitadel-email-valkey.yaml").read_text()
    )
    values = app["spec"]["source"]["helm"]["valuesObject"]
    assert app["spec"]["destination"]["namespace"] == "zitadel"
    assert values["auth"] == {"enabled": True, "existingSecret": "zitadel-email-valkey"}
    assert values["acl"]["enabled"] is False
    assert values["valkey"]["maxmemoryPolicy"] == "noeviction"
    assert values["persistence"]["enabled"] is True
    assert values["replicaCount"] == 3
    assert values["networkPolicy"]["allowedNamespaces"] == []
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "zitadel-email-valkey",
            str(ROOT / "charts/apps/global-valkey"),
            "--namespace",
            "zitadel",
            "--values",
            "-",
        ],
        input=yaml.safe_dump(values),
        text=True,
        capture_output=True,
        check=True,
    )
    docs = [d for d in yaml.safe_load_all(rendered.stdout) if d]
    for workload in (d for d in docs if d["kind"] in ("StatefulSet", "Deployment")):
        assert (
            workload["spec"]["template"]["spec"]["serviceAccountName"]
            == "zitadel-email-valkey"
        )
        for container in workload["spec"]["template"]["spec"]["containers"]:
            assert any(
                e.get("valueFrom", {}).get("secretKeyRef", {}).get("name")
                == "zitadel-email-valkey"
                for e in container.get("env", [])
            )


def test_email_secret_reader_has_one_exact_openbao_path():
    values = yaml.safe_load(
        (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
    )["bootstrap"]
    name = "read-zitadel-email-zitadel-production"
    policy = next(p["hcl"] for p in values["policies"] if p["name"] == name)
    assert re.findall(r'path "([^"]+)"', policy) == [
        "kv/data/zitadel/prod/app/zitadel-email-valkey-password"
    ]
    assert 'capabilities = ["read"]' in policy
    role = next(r for r in values["kubernetesRoles"] if r["name"] == name)
    assert role["serviceAccounts"] == ["zitadel-email-production-reader"]
    assert role["namespaces"] == ["zitadel"]
    docs = list(
        yaml.safe_load_all(
            (ROOT / "external-secrets/prod/zitadel/email-valkey.yaml").read_text()
        )
    )
    secret = next(d for d in docs if d["kind"] == "ExternalSecret")
    assert (
        secret["spec"]["secretStoreRef"]["name"] == "openbao-zitadel-email-production"
    )
    assert secret["spec"]["data"][0]["remoteRef"] == {
        "key": "zitadel/prod/app/zitadel-email-valkey-password",
        "property": "value",
    }
    data = secret["spec"]["target"]["template"]["data"]
    assert (
        "zitadel-email-valkey.zitadel.svc.cluster.local:6379"
        in data["CONSUMER_EMAIL_VALKEY_URL"]
    )
    assert "{{ .password }}" in data["password"]


def test_email_state_mesh_access_is_limited_to_login_and_its_own_cluster():
    docs = list(
        yaml.safe_load_all(
            (
                ROOT / "external-secrets/prod/zitadel/email-valkey-network.yaml"
            ).read_text()
        )
    )
    deny = next(d for d in docs if d["kind"] == "AuthorizationPolicy")
    assert deny["spec"]["action"] == "DENY"
    assert deny["spec"]["rules"][0]["from"][0]["source"]["notPrincipals"] == [
        "cluster.local/ns/zitadel/sa/zitadel-login",
        "cluster.local/ns/zitadel/sa/zitadel-email-valkey",
    ]
    assert (
        deny["spec"]["selector"]["matchLabels"]["app.kubernetes.io/name"]
        == "zitadel-email-valkey"
    )
    login = next(
        d
        for d in docs
        if d["kind"] == "NetworkPolicy"
        and d["metadata"]["name"] == "zitadel-login-email-egress"
    )
    assert (
        login["spec"]["podSelector"]["matchLabels"]["app.kubernetes.io/name"]
        == "zitadel-login"
    )
    assert login["spec"]["egress"][0]["ports"] == [{"protocol": "TCP", "port": 6379}]


def test_optional_email_secret_cannot_block_existing_login_pods():
    values = yaml.safe_load(
        (ROOT / "charts/thirdparty/zitadel/values.yaml").read_text()
    )
    env = next(
        e
        for e in values["zitadel"]["login"]["env"]
        if e["name"] == "CONSUMER_EMAIL_VALKEY_URL"
    )
    assert env["valueFrom"]["secretKeyRef"] == {
        "name": "zitadel-email-valkey",
        "key": "CONSUMER_EMAIL_VALKEY_URL",
        "optional": True,
    }


def test_rendered_login_uses_candidate_and_optional_secret_without_api_upgrade():
    output = subprocess.check_output(
        [
            "helm",
            "template",
            "zitadel",
            str(ROOT / "charts/thirdparty/zitadel"),
            "--namespace",
            "zitadel",
        ],
        text=True,
    )
    deployments = {
        d["metadata"]["name"]: d
        for d in yaml.safe_load_all(output)
        if d and d["kind"] == "Deployment"
    }
    login = deployments["zitadel-login"]["spec"]["template"]["spec"]
    assert login["serviceAccountName"] == "zitadel-login"
    container = next(c for c in login["containers"] if c["name"] == "zitadel-login")
    assert container["image"].endswith(
        "feat-consumer-email-otp-e688e06@sha256:856166971b3f157e61860778ab4ba1d76f52a21cde8466e1984aa8dbfb59d103"
    )
    env = next(e for e in container["env"] if e["name"] == "CONSUMER_EMAIL_VALKEY_URL")
    assert env["valueFrom"]["secretKeyRef"]["optional"] is True
    api = deployments["zitadel"]["spec"]["template"]["spec"]["containers"][0]
    assert (
        "sha-29986e1b8b3e606d20871a2e73874b91f9b5b695@sha256:22ab1fb4abe6a5f279c5509fa2bbb10358a2fc9fb479af013235add8af1188ac"
        in api["image"]
    )


def test_existing_cache_proxy_identity_remains_unchanged():
    output = subprocess.check_output(
        [
            "helm",
            "template",
            "global-valkey-cache",
            str(ROOT / "charts/apps/global-valkey"),
            "--values",
            str(ROOT / "charts/apps/global-valkey/values-cache.yaml"),
        ],
        text=True,
    )
    proxy = next(
        d for d in yaml.safe_load_all(output) if d and d["kind"] == "Deployment"
    )
    assert "serviceAccountName" not in proxy["spec"]["template"]["spec"]


def test_operator_crd_allows_optional_email_only_and_explicit_revocation():
    docs = yaml.safe_load_all(
        (ROOT / "k8s/operators/zitadel/resources.yaml").read_text()
    )
    crd = next(
        d
        for d in docs
        if d
        and d.get("metadata", {}).get("name") == "zitadelprojects.identity.tesserix.app"
    )
    spec = crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]
    consumer = spec["properties"]["consumerOrganization"]
    assert "emailOtp" not in consumer["required"]
    assert consumer["properties"]["emailOtp"]["type"] == "boolean"
    assert "default" not in consumer["properties"]["emailOtp"]
    assert consumer["properties"]["providers"]["minItems"] == 0
    rules = {v["rule"] for v in consumer["x-kubernetes-validations"]}
    assert "has(self.emailOtp) || size(self.providers) > 0" in rules
    assert "!has(oldSelf.emailOtp) || has(self.emailOtp)" in rules


def test_isolated_email_test_claim_starts_disabled_with_loopback_pkce_client():
    docs = list(
        yaml.safe_load_all(
            (ROOT / "k8s/operators/zitadel/claims/email-otp-test.yaml").read_text()
        )
    )
    project, application = docs
    assert project["metadata"]["name"] == "email-otp-test"
    assert project["spec"]["organization"] == "Tesserix Email OTP Test"
    assert project["spec"]["consumerOrganization"]["emailOtp"] is False
    assert project["spec"]["consumerOrganization"]["providers"] == []
    assert application["spec"]["projectRef"]["name"] == "email-otp-test"
    assert application["spec"]["applicationType"] == "native"
    assert application["spec"]["redirectUris"] == ["http://127.0.0.1:18085/callback"]
    assert application["spec"]["refreshToken"] is False
    assert (
        application["spec"]["loginBaseUri"] == "https://auth.tesserix.app/ui/v2/login/"
    )


def test_seed_identity_can_only_create_or_read_its_password():
    values = yaml.safe_load(
        (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
    )["bootstrap"]
    policy = next(
        p["hcl"]
        for p in values["policies"]
        if p["name"] == "seed-zitadel-email-production"
    )
    assert re.findall(r'path "([^"]+)"', policy) == [
        "kv/data/zitadel/prod/app/zitadel-email-valkey-password",
        "auth/token/revoke-self",
    ]
    assert 'capabilities = ["create", "read"]' in policy
    role = next(
        r
        for r in values["kubernetesRoles"]
        if r["name"] == "seed-zitadel-email-production"
    )
    assert role["serviceAccounts"] == ["zitadel-email-secret-seed"]
    assert role["namespaces"] == ["zitadel"]
    assert role["audience"] == "openbao"
    network = yaml.safe_load(
        (ROOT / "charts/apps/openbao-namespace/values.yaml").read_text()
    )
    assert "zitadel/zitadel-email-secret-seed" in network["allowedPrincipals"]
    assert {
        "namespace": "zitadel",
        "podLabels": {"app.kubernetes.io/name": "zitadel-email-secret-seed"},
    } in network["allowedPodSources"]
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod/zitadel")],
                text=True,
            )
        )
    )
    job = next(
        d
        for d in docs
        if d["kind"] == "Job"
        and d["metadata"]["name"] == "zitadel-email-secret-seed-v1"
    )
    pod = job["spec"]["template"]["spec"]
    assert pod["serviceAccountName"] == "zitadel-email-secret-seed"
    assert pod["automountServiceAccountToken"] is False
    assert (
        pod["volumes"][1]["projected"]["sources"][0]["serviceAccountToken"]["audience"]
        == "openbao"
    )
    assert "@sha256:" in pod["containers"][0]["image"]
