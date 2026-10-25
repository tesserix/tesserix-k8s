import subprocess
from pathlib import Path

import yaml


class StrictLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node):
    keys = set()
    for key, _ in node.value:
        value = loader.construct_object(key)
        if value in keys:
            raise ValueError(f"duplicate YAML key: {value}")
        keys.add(value)
    return yaml.SafeLoader.construct_mapping(loader, node)


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping
)

ROOT = Path(__file__).resolve().parents[1]
CLAIM_PATH = "/internal/v1/mediconnect/current-claim"
API_PRINCIPAL = "cluster.local/ns/helivanta/sa/helivanta-api"
GLOBAL_PRINCIPAL = "cluster.local/ns/helivanta/sa/helivanta-global-api"


def render(chart, *values):
    args = [
        "helm",
        "template",
        chart,
        str(ROOT / "charts/apps" / chart),
        "--namespace",
        "helivanta",
    ]
    for value in values:
        args.extend(["--set", value])
    return [
        row
        for row in yaml.load_all(
            subprocess.check_output(args, text=True), Loader=StrictLoader
        )
        if row
    ]


def named(rows, kind, name):
    return next(
        row for row in rows if row["kind"] == kind and row["metadata"]["name"] == name
    )


def test_claim_workload_is_disabled_by_default():
    rows = render("helivanta-api")
    pod = named(rows, "Deployment", "helivanta-api")["spec"]["template"]["spec"]
    assert not any(
        env["name"].startswith("MEDICONNECT_CLAIM_")
        for env in pod["containers"][0]["env"]
    )
    assert not any(row["kind"] in {"ClusterRole", "ClusterRoleBinding"} for row in rows)


def test_enabled_claim_owner_has_explicit_short_lived_credentials_and_minimal_review_rbac():
    rows = render(
        "helivanta-api",
        "clinicalConsent.enabled=true",
        "clinicalConsent.kubernetesApiCIDR=172.16.0.2/32",
    )
    pod = named(rows, "Deployment", "helivanta-api")["spec"]["template"]["spec"]
    assert pod["automountServiceAccountToken"] is False
    env = {item["name"]: item.get("value") for item in pod["containers"][0]["env"]}
    assert env["MEDICONNECT_CLAIM_VERIFICATION_ENABLED"] == "true"
    assert (
        env["MEDICONNECT_CLAIM_CALLER"]
        == "system:serviceaccount:helivanta:helivanta-api"
    )
    assert (
        env["MEDICONNECT_CLAIM_ORIGIN"]
        == "http://helivanta-api.helivanta.svc.cluster.local:8080"
    )
    assert env["MEDICONNECT_CLAIM_TRANSPORT"] == "istio-mtls"
    assert (
        env["MEDICONNECT_CLAIM_TOKEN_FILE"]
        == "/var/run/secrets/mediconnect-claim/token"
    )
    volumes = {item["name"]: item for item in pod["volumes"]}
    claim = volumes["mediconnect-claim"]["projected"]["sources"][0][
        "serviceAccountToken"
    ]
    assert claim == {
        "audience": "helivanta-mediconnect-claim",
        "expirationSeconds": 600,
        "path": "token",
    }
    kube = volumes["kubernetes-api"]["projected"]["sources"]
    assert kube[0]["serviceAccountToken"] == {"expirationSeconds": 600, "path": "token"}
    assert kube[1]["configMap"]["name"] == "kube-root-ca.crt"
    assert (
        kube[2]["downwardAPI"]["items"][0]["fieldRef"]["fieldPath"]
        == "metadata.namespace"
    )
    mounts = {item["name"]: item for item in pod["containers"][0]["volumeMounts"]}
    assert (
        mounts["kubernetes-api"]["mountPath"]
        == "/var/run/secrets/kubernetes.io/serviceaccount"
    )
    assert mounts["mediconnect-claim"]["readOnly"] is True
    assert not any(row["kind"] in {"ClusterRole", "ClusterRoleBinding"} for row in rows)
    identity = render("helivanta-workload-identity")
    role = named(identity, "ClusterRole", "helivanta-api-helivanta-claim-review")
    assert role["rules"] == [
        {
            "apiGroups": ["authentication.k8s.io"],
            "resources": ["tokenreviews"],
            "verbs": ["create"],
        }
    ]
    binding = named(
        identity, "ClusterRoleBinding", "helivanta-api-helivanta-claim-review"
    )
    assert binding["subjects"] == [
        {"kind": "ServiceAccount", "name": "helivanta-api", "namespace": "helivanta"}
    ]
    assert (
        named(rows, "Deployment", "helivanta-api")["spec"]["template"]["metadata"][
            "labels"
        ]["sidecar.istio.io/inject"]
        == "true"
    )
    policy = named(rows, "NetworkPolicy", "helivanta-api-claim-review")
    assert policy["spec"]["egress"] == [
        {
            "to": [{"ipBlock": {"cidr": "172.16.0.2/32"}}],
            "ports": [{"protocol": "TCP", "port": 443}],
        }
    ]


def test_owner_boundary_carves_only_the_internal_claim_and_denies_global_identity():
    enabled = "clinicalConsent.enabled=true"
    rows = render("helivanta-global-api", enabled)
    assert (
        named(rows, "PeerAuthentication", "helivanta-global-api-owner")["spec"]["mtls"][
            "mode"
        ]
        == "STRICT"
    )
    deny = named(rows, "AuthorizationPolicy", "helivanta-owner-requires-global-api")[
        "spec"
    ]
    assert deny["action"] == "DENY"
    outer, internal = deny["rules"]
    assert outer["from"][0]["source"]["notPrincipals"] == [GLOBAL_PRINCIPAL]
    assert outer["to"][0]["operation"] == {"ports": ["8080"], "notPaths": [CLAIM_PATH]}
    assert internal["from"][0]["source"]["notPrincipals"] == [API_PRINCIPAL]
    assert internal["to"][0]["operation"] == {"ports": ["8080"], "paths": [CLAIM_PATH]}
    allow = named(rows, "AuthorizationPolicy", "helivanta-claim-owner")["spec"]
    assert allow["action"] == "ALLOW"
    assert allow["rules"] == [
        {
            "from": [{"source": {"principals": [API_PRINCIPAL]}}],
            "to": [
                {
                    "operation": {
                        "ports": ["8080"],
                        "methods": ["POST"],
                        "paths": [CLAIM_PATH],
                    }
                }
            ],
        }
    ]


def test_claim_review_requires_an_exact_control_plane_address():
    for value in ["", "0.0.0.0/0", "172.16.0.0/28", "999.16.0.2/32"]:
        result = subprocess.run(
            [
                "helm",
                "template",
                "helivanta-api",
                str(ROOT / "charts/apps/helivanta-api"),
                "--set",
                "clinicalConsent.enabled=true",
                "--set",
                f"clinicalConsent.kubernetesApiCIDR={value}",
            ],
            text=True,
            check=False,
            capture_output=True,
        )
        assert result.returncode != 0
        assert (
            "clinicalConsent.kubernetesApiCIDR must be an explicit IPv4 /32"
            in result.stderr
        )


def test_claim_exception_cannot_disable_the_global_owner_boundary():
    result = subprocess.run(
        [
            "helm",
            "template",
            "helivanta-global-api",
            str(ROOT / "charts/apps/helivanta-global-api"),
            "--set",
            "clinicalConsent.enabled=true",
            "--set",
            "enforceOwnerBoundary=false",
        ],
        text=True,
        check=False,
        capture_output=True,
    )
    assert result.returncode != 0
    assert "clinicalConsent requires enforceOwnerBoundary" in result.stderr


def test_transit_consent_key_creation_is_constrained_and_not_granted_to_eso():
    import json
    import re

    rendered = subprocess.check_output(
        [
            "helm",
            "template",
            "openbao",
            str(ROOT / "charts/thirdparty/openbao"),
            "--namespace",
            "openbao",
        ],
        text=True,
    )
    config = named(
        [row for row in yaml.safe_load_all(rendered) if row],
        "ConfigMap",
        "openbao-bootstrap",
    )["data"]
    policy = config["policy-helivanta-clinical-consent.hcl"]
    assert re.findall(r'path "([^"]+)"', policy) == [
        "transit/keys/helivanta-consent-*",
        "transit/keys/+/*",
        "transit/hmac/helivanta-consent-*",
    ]
    assert 'capabilities = ["create", "update"]' in policy
    assert (
        'required_parameters = ["type", "key_size", "exportable", "allow_plaintext_backup"]'
        in policy
    )
    for value in [
        '"type" = ["hmac"]',
        '"key_size" = ["32"]',
        '"exportable" = [false]',
        '"allow_plaintext_backup" = [false]',
    ]:
        assert value in policy
    assert 'path "transit/keys/+/*" { capabilities = ["deny"] }' in policy
    assert (
        'path "transit/hmac/helivanta-consent-*" { capabilities = ["update"] }'
        in policy
    )
    assert '"read"' not in policy
    role = json.loads(config["role-helivanta-api-transit.json"])
    assert role["bound_service_account_names"] == ["helivanta-api"]
    assert role["bound_service_account_namespaces"] == ["helivanta"]
    assert role["token_policies"] == [
        "helivanta-api-transit",
        "helivanta-clinical-consent",
    ]
    for name, body in config.items():
        if name.startswith("role-") and name != "role-helivanta-api-transit.json":
            assert (
                "helivanta-clinical-consent" not in json.loads(body)["token_policies"]
            )


def test_claim_owner_cannot_miss_the_canonical_mesh_selector_or_identity():
    for setting, message in [
        ("nameOverride=unexpected", "canonical helivanta-api workload selector"),
        (
            "serviceAccount.name=helivanta-global-api",
            "helivanta-api owner service account",
        ),
    ]:
        result = subprocess.run(
            [
                "helm",
                "template",
                "helivanta-api",
                str(ROOT / "charts/apps/helivanta-api"),
                "--namespace",
                "helivanta",
                "--set",
                "clinicalConsent.enabled=true",
                "--set",
                "clinicalConsent.kubernetesApiCIDR=172.16.0.2/32",
                "--set",
                setting,
            ],
            text=True,
            check=False,
            capture_output=True,
        )
        assert result.returncode != 0
        assert message in result.stderr


def test_tokenreview_delivery_uses_platform_project_without_broadening_product_authority():
    application = yaml.safe_load(
        (ROOT / "argocd/prod/apps/global/helivanta-workload-identity.yaml").read_text()
    )
    assert application["spec"]["project"] == "platform"
    assert application["spec"]["destination"]["namespace"] == "helivanta"
    assert (
        application["spec"]["source"]["path"]
        == "charts/apps/helivanta-workload-identity"
    )
    project = yaml.safe_load((ROOT / "argocd/prod/projects/helivanta.yaml").read_text())
    assert not any(
        rule["group"] == "rbac.authorization.k8s.io"
        for rule in project["spec"]["clusterResourceWhitelist"]
    )
    kustomization = yaml.safe_load(
        (ROOT / "argocd/prod/apps/global/kustomization.yaml").read_text()
    )
    assert "helivanta-workload-identity.yaml" in kustomization["resources"]


def test_production_activation_pairs_both_boundaries_and_isolates_review_egress():
    import ipaddress
    import tempfile

    deployed = {}
    for chart in ["helivanta-api", "helivanta-global-api"]:
        application = yaml.safe_load(
            (ROOT / f"argocd/prod/apps/helivanta/{chart}.yaml").read_text()
        )
        settings = application["spec"]["source"]["helm"]["valuesObject"]
        assert settings["clinicalConsent"]["enabled"] is True
        deployed[chart] = settings
    network = ipaddress.ip_network(
        deployed["helivanta-api"]["clinicalConsent"]["kubernetesApiCIDR"]
    )
    assert network.version == 4 and network.prefixlen == 32
    with tempfile.TemporaryDirectory() as directory:
        values = Path(directory) / "values.yaml"
        values.write_text(yaml.safe_dump(deployed["helivanta-api"]))
        rendered = subprocess.check_output(
            [
                "helm",
                "template",
                "helivanta-api",
                str(ROOT / "charts/apps/helivanta-api"),
                "--namespace",
                "helivanta",
                "-f",
                str(values),
            ],
            text=True,
        )
        rows = [row for row in yaml.load_all(rendered, Loader=StrictLoader) if row]
    policy = named(rows, "NetworkPolicy", "helivanta-api-claim-review")
    assert (
        policy["spec"]["podSelector"]["matchLabels"]["app.kubernetes.io/component"]
        == "api"
    )
    migration = next(row for row in rows if row["kind"] == "Job")
    assert (
        migration["spec"]["template"]["metadata"]["labels"][
            "app.kubernetes.io/component"
        ]
        == "migrate"
    )


def test_proxy_capture_is_explicitly_disabled_until_readers_are_ready():
    rows = render("helivanta-api")
    pod = named(rows, "Deployment", "helivanta-api")["spec"]["template"]["spec"]
    env = {item["name"]: item.get("value") for item in pod["containers"][0]["env"]}
    assert env["PATIENTMASTER_PROXY_CLINICAL_CAPTURE_ENABLED"] == "false"

    rows = render(
        "helivanta-api",
        "clinicalConsent.enabled=true",
        "clinicalConsent.kubernetesApiCIDR=172.16.0.2/32",
        "clinicalConsent.proxyCaptureEnabled=true",
    )
    pod = named(rows, "Deployment", "helivanta-api")["spec"]["template"]["spec"]
    env = {item["name"]: item.get("value") for item in pod["containers"][0]["env"]}
    assert env["PATIENTMASTER_PROXY_CLINICAL_CAPTURE_ENABLED"] == "true"
    assert env["MEDICONNECT_CLAIM_VERIFICATION_ENABLED"] == "true"


def test_proxy_capture_cannot_bypass_the_live_claim_verifier():
    result = subprocess.run(
        [
            "helm",
            "template",
            "helivanta-api",
            str(ROOT / "charts/apps/helivanta-api"),
            "--set",
            "clinicalConsent.proxyCaptureEnabled=true",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert "proxy clinical capture requires clinicalConsent.enabled" in result.stderr
