from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
ROUTE = ROOT / "manifests/agentic-istio/publisher-route.yaml"


def documents():
    return [doc for doc in yaml.safe_load_all(ROUTE.read_text()) if doc]


def resource(kind, name):
    return next(
        doc
        for doc in documents()
        if doc["kind"] == kind and doc["metadata"]["name"] == name
    )


def test_publisher_route_is_dns_only_tls_and_exact_path():
    gateway = resource("Gateway", "agentregistry-publisher")
    assert gateway["metadata"]["labels"] == {
        "external-dns.tesserix.app/scope": "agentregistry-publisher"
    }
    annotations = gateway["metadata"]["annotations"]
    assert annotations["external-dns.alpha.kubernetes.io/target"] == "34.14.139.74"
    assert annotations["external-dns.alpha.kubernetes.io/cloudflare-proxied"] == "false"
    assert gateway["spec"]["selector"] == {"istio": "custom-ingressgateway"}
    assert gateway["spec"]["servers"] == [
        {
            "hosts": ["publish.aregistry.tesserix.app"],
            "port": {
                "name": "https-agentregistry-publisher",
                "number": 443,
                "protocol": "HTTPS",
            },
            "tls": {
                "credentialName": "agentregistry-publisher-tls",
                "minProtocolVersion": "TLSV1_2",
                "mode": "SIMPLE",
            },
        }
    ]

    certificate = resource("Certificate", "agentregistry-publisher")
    assert certificate["spec"]["dnsNames"] == ["publish.aregistry.tesserix.app"]
    assert certificate["spec"]["issuerRef"] == {
        "kind": "ClusterIssuer",
        "name": "letsencrypt-custom-domain",
    }
    assert certificate["spec"]["secretName"] == "agentregistry-publisher-tls"

    virtual_service = resource("VirtualService", "agentregistry-publisher")
    assert virtual_service["spec"]["gateways"] == [
        "istio-ingress/agentregistry-publisher"
    ]
    assert virtual_service["spec"]["hosts"] == ["publish.aregistry.tesserix.app"]
    assert virtual_service["spec"]["http"] == [
        {
            "match": [
                {
                    "method": {"exact": "POST"},
                    "uri": {"exact": "/v0/apply"},
                }
            ],
            "route": [
                {
                    "destination": {
                        "host": "agentregistry.agentregistry-system.svc.cluster.local",
                        "port": {"number": 12121},
                    }
                }
            ],
            "timeout": "30s",
        }
    ]


def test_publisher_route_requires_exact_github_identity():
    request_auth = resource("RequestAuthentication", "agentregistry-publisher-github")
    jwt_rule = request_auth["spec"]["jwtRules"][0]
    assert request_auth["spec"]["selector"] == {
        "matchLabels": {"istio": "custom-ingressgateway"}
    }
    assert jwt_rule["issuer"] == "https://token.actions.githubusercontent.com"
    assert jwt_rule["audiences"] == ["agentregistry-publisher.tesserix.app"]
    assert jwt_rule["fromHeaders"] == [
        {"name": "X-GitHub-OIDC-Token", "prefix": "Bearer "}
    ]

    policy = resource("AuthorizationPolicy", "agentregistry-publisher")
    required_principal = (
        "https://token.actions.githubusercontent.com/"
        "repo:tesserix/ai-agents:ref:refs/heads/main"
    )
    assert policy["spec"]["action"] == "DENY"
    assert policy["spec"]["selector"] == {
        "matchLabels": {"istio": "custom-ingressgateway"}
    }
    assert policy["spec"]["rules"] == [
        {
            "from": [
                {"source": {"notRequestPrincipals": [required_principal]}}
            ],
            "to": [
                {
                    "operation": {
                        "hosts": ["publish.aregistry.tesserix.app"]
                    }
                }
            ],
        },
        {
            "to": [
                {
                    "operation": {
                        "hosts": ["publish.aregistry.tesserix.app"],
                        "notMethods": ["POST"],
                    }
                }
            ]
        },
        {
            "to": [
                {
                    "operation": {
                        "hosts": ["publish.aregistry.tesserix.app"],
                        "notPaths": ["/v0/apply"],
                    }
                }
            ]
        },
    ]


def test_route_is_reconciled_and_origin_principal_is_allowed():
    kustomization = yaml.safe_load(
        (ROOT / "manifests/agentic-istio/kustomization.yaml").read_text()
    )
    assert "publisher-route.yaml" in kustomization["resources"]

    policy_text = (
        ROOT / "manifests/agentic-istio/authorization-policy.yaml"
    ).read_text()
    principal = "cluster.local/ns/istio-ingress/sa/custom-ingressgateway"
    assert principal in policy_text

    infrastructure = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/kustomization.yaml").read_text()
    )
    assert "external-dns-agentregistry-publisher.yaml" in infrastructure["resources"]

    app = yaml.safe_load(
        (
            ROOT
            / "argocd/prod/infrastructure/external-dns-agentregistry-publisher.yaml"
        ).read_text()
    )
    values = yaml.safe_load(app["spec"]["source"]["helm"]["values"])
    assert values["domainFilters"] == ["tesserix.app"]
    assert values["labelFilter"] == (
        "external-dns.tesserix.app/scope=agentregistry-publisher"
    )
    assert values["sources"] == ["istio-gateway"]
    assert "--managed-record-types=A" in values["extraArgs"]
    assert "--cloudflare-proxied" not in values["extraArgs"]
