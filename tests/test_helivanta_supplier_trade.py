import subprocess

from test_helivanta_clinical_consent import ROOT, named, render

PATH = "/v1/supply/internal/trading-source/check"
ENABLED = (
    "supplierTrade.enabled=true",
    "supplierTrade.kubernetesApiCIDR=172.16.0.2/32",
)


def test_supplier_trade_disabled_by_default():
    rows = render("helivanta-api")
    pod = named(rows, "Deployment", "helivanta-api")["spec"]["template"]["spec"]
    assert not any(
        e["name"].startswith("SUPPLIER_TRADE_") for e in pod["containers"][0]["env"]
    )
    assert not any(
        r["metadata"]["name"] == "helivanta-supplier-trade-owner" for r in rows
    )


def test_supplier_trade_projects_rotating_identity_without_clinical_dependency():
    for clinical in [False, True]:
        rows = render(
            "helivanta-api",
            *ENABLED,
            f"clinicalConsent.enabled={str(clinical).lower()}",
            "clinicalConsent.kubernetesApiCIDR=172.16.0.2/32",
        )
        pod = named(rows, "Deployment", "helivanta-api")["spec"]["template"]["spec"]
        assert pod["automountServiceAccountToken"] is False
        env = {e["name"]: e.get("value") for e in pod["containers"][0]["env"]}
        assert {k: v for k, v in env.items() if k.startswith("SUPPLIER_TRADE_")} == {
            "SUPPLIER_TRADE_CURRENT_URL": f"http://helivanta-api.helivanta.svc.cluster.local:8080{PATH}",
            "SUPPLIER_TRADE_CALLER_ACCOUNT": "system:serviceaccount:helivanta:helivanta-api",
            "SUPPLIER_TRADE_TOKEN_FILE": "/var/run/secrets/supplier-trade/token",
        }
        volumes = {v["name"]: v for v in pod["volumes"]}
        assert len(volumes) == len(pod["volumes"])
        assert volumes["supplier-trade"]["projected"]["sources"] == [
            {
                "serviceAccountToken": {
                    "audience": "helivanta-supplier-trade-current",
                    "expirationSeconds": 600,
                    "path": "token",
                }
            }
        ]
        assert volumes["kubernetes-api"]["projected"]["sources"][0][
            "serviceAccountToken"
        ] == {"expirationSeconds": 600, "path": "token"}
        mounts = pod["containers"][0]["volumeMounts"]
        assert len({m["name"] for m in mounts}) == len(mounts)
        assert (
            next(m for m in mounts if m["name"] == "supplier-trade")["readOnly"] is True
        )
        assert (
            named(rows, "Deployment", "helivanta-api")["spec"]["template"]["metadata"][
                "labels"
            ]["sidecar.istio.io/inject"]
            == "true"
        )
        assert not any(r["kind"] in {"ClusterRole", "ClusterRoleBinding"} for r in rows)


def test_supplier_trade_boundary_only_admits_api_principal_on_exact_post():
    rows = render("helivanta-api", *ENABLED)
    allow = named(rows, "AuthorizationPolicy", "helivanta-supplier-trade-owner")["spec"]
    assert allow["rules"] == [
        {
            "from": [
                {
                    "source": {
                        "principals": ["cluster.local/ns/helivanta/sa/helivanta-api"]
                    }
                }
            ],
            "to": [
                {"operation": {"ports": ["8080"], "methods": ["POST"], "paths": [PATH]}}
            ],
        }
    ]
    network = named(rows, "NetworkPolicy", "helivanta-api-supplier-trade")["spec"]
    peer = {
        "podSelector": {
            "matchLabels": {
                "app.kubernetes.io/name": "helivanta-api",
                "app.kubernetes.io/instance": "helivanta-api",
                "app.kubernetes.io/component": "api",
            }
        }
    }
    assert network["ingress"] == [
        {"from": [peer], "ports": [{"protocol": "TCP", "port": 8080}]}
    ]
    assert network["egress"] == [
        {"to": [peer], "ports": [{"protocol": "TCP", "port": 8080}]},
        {
            "to": [{"ipBlock": {"cidr": "172.16.0.2/32"}}],
            "ports": [{"protocol": "TCP", "port": 443}],
        },
    ]
    for clinical in [False, True]:
        rows = render(
            "helivanta-global-api",
            "supplierTrade.enabled=true",
            f"clinicalConsent.enabled={str(clinical).lower()}",
        )
        rules = named(
            rows, "AuthorizationPolicy", "helivanta-owner-requires-global-api"
        )["spec"]["rules"]
        paths = [PATH] + (
            ["/internal/v1/mediconnect/current-claim"] if clinical else []
        )
        assert set(rules[0]["to"][0]["operation"]["notPaths"]) == set(paths)
        assert set(rules[1]["to"][0]["operation"]["paths"]) == set(paths)
        assert rules[1]["from"][0]["source"]["notPrincipals"] == [
            "cluster.local/ns/helivanta/sa/helivanta-api"
        ]


def test_supplier_trade_invalid_configuration_fails_closed():
    for setting in [
        "supplierTrade.kubernetesApiCIDR=",
        "supplierTrade.kubernetesApiCIDR=0.0.0.0/0",
        "supplierTrade.kubernetesApiCIDR=999.0.0.1/32",
        "nameOverride=wrong",
        "serviceAccount.name=wrong",
    ]:
        result = subprocess.run(
            [
                "helm",
                "template",
                "helivanta-api",
                str(ROOT / "charts/apps/helivanta-api"),
                "--set",
                ENABLED[0],
                "--set",
                ENABLED[1],
                "--set",
                setting,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0
        assert (
            "supplierTrade requires" in result.stderr
            or "supplierTrade.kubernetesApiCIDR" in result.stderr
        )
    result = subprocess.run(
        [
            "helm",
            "template",
            "helivanta-global-api",
            str(ROOT / "charts/apps/helivanta-global-api"),
            "--set",
            "supplierTrade.enabled=true",
            "--set",
            "enforceOwnerBoundary=false",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "supplierTrade requires enforceOwnerBoundary" in result.stderr


def test_production_pairs_owner_and_gateway_without_static_credentials():
    import tempfile

    import yaml

    deployed = {}
    for chart in ["helivanta-api", "helivanta-global-api"]:
        app = yaml.safe_load(
            (ROOT / f"argocd/prod/apps/helivanta/{chart}.yaml").read_text()
        )
        settings = app["spec"]["source"]["helm"]["valuesObject"]
        assert settings["supplierTrade"]["enabled"] is True
        deployed[chart] = settings
    assert (
        deployed["helivanta-api"]["supplierTrade"]["kubernetesApiCIDR"]
        == "172.16.0.2/32"
    )
    with tempfile.TemporaryDirectory() as directory:
        for chart, settings in deployed.items():
            values = ROOT / directory / "values.yaml"
            values.write_text(yaml.safe_dump(settings))
            subprocess.run(
                [
                    "helm",
                    "template",
                    chart,
                    str(ROOT / "charts/apps" / chart),
                    "--namespace",
                    "helivanta",
                    "-f",
                    str(values),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
