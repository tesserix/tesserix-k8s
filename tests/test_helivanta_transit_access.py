import json
import pathlib
import re
import subprocess

import yaml

ROOT = pathlib.Path(__file__).parents[1]
PRINCIPAL = "cluster.local/ns/helivanta/sa/helivanta-api"


def render(chart, *args, namespace="openbao"):
    output = subprocess.run(
        ["helm", "template", "release", str(ROOT / chart), "--namespace", namespace, *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [doc for doc in yaml.safe_load_all(output) if doc]


def resource(documents, kind, name):
    return next(
        doc
        for doc in documents
        if doc["kind"] == kind and doc["metadata"]["name"] == name
    )


def bootstrap():
    documents = render("charts/thirdparty/openbao")
    return resource(documents, "ConfigMap", "openbao-bootstrap")["data"]


def api(*settings):
    args = [a for s in settings for a in ("--set", s)]
    documents = render("charts/apps/helivanta-api", *args, namespace="helivanta")
    return resource(documents, "Deployment", "helivanta-api")["spec"]["template"]["spec"]


PROD = ("documents.enabled=true", "documents.acceptUploads=true", "supplyEvidence.enabled=true")


def test_bootstrap_mounts_transit_after_kv_and_before_policies():
    script = bootstrap()["bootstrap.sh"]
    kv = script.index("/v1/sys/mounts/kv")
    transit = re.search(r"/v1/sys/mounts/transit \\\s+'\{\"type\":\"transit\"\}'", script).start()
    assert kv < transit < script.index("==> policies")


def test_transit_policy_grants_only_required_operations_on_scoped_helivanta_keys():
    policy = bootstrap()["policy-helivanta-api-transit.hcl"]
    assert re.findall(r'path "([^"]+)"\s*\{ capabilities = \[([^]]+)\] \}', policy) == [
        ("transit/encrypt/helivanta-staff-*", '"create", "update"'),
        ("transit/decrypt/helivanta-staff-*", '"update"'),
        ("transit/hmac/helivanta-staff-*", '"update"'),
        ("transit/encrypt/helivanta-emergency-*", '"create", "update"'),
        ("transit/decrypt/helivanta-emergency-*", '"update"'),
        ("transit/hmac/helivanta-emergency-*", '"update"'),
        ("transit/encrypt/helivanta-payments-credentials", '"create", "update"'),
        ("transit/decrypt/helivanta-payments-credentials", '"update"'),
    ]
    assert "kv/" not in policy
    for forbidden in ("keys/", "export", "rotate", "rewrap", "backup", "restore", "delete", "sudo"):
        assert forbidden not in policy


def test_transit_role_is_bound_to_the_api_alone_and_separate_from_eso():
    config = bootstrap()
    role = json.loads(config["role-helivanta-api-transit.json"])
    assert role == {
        "bound_service_account_names": ["helivanta-api"],
        "bound_service_account_namespaces": ["helivanta"],
        "token_policies": ["helivanta-api-transit", "helivanta-clinical-consent"],
        "token_ttl": "1h",
    }
    for name, body in config.items():
        if name.startswith("role-") and name != "role-helivanta-api-transit.json":
            assert "helivanta-api-transit" not in json.loads(body)["token_policies"]


def test_openbao_admits_only_the_api_and_create_only_seed_from_helivanta():
    documents = render("charts/apps/openbao-namespace")
    ingress = resource(documents, "NetworkPolicy", "allow-clients-to-openbao")["spec"][
        "ingress"
    ][0]
    sources = [
        source
        for source in ingress["from"]
        if source.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name")
        == "helivanta"
    ]
    assert sources == [
        {
            "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "helivanta"}},
            "podSelector": {"matchLabels": {"app.kubernetes.io/name": name}},
        }
        for name in ["helivanta-emergency-secret-seed", "helivanta-pharmacy-evidence-secret-seed", "helivanta-privacy-secret-seed", "helivanta-api"]
    ]
    assert ingress["ports"] == [{"protocol": "TCP", "port": 8200}]
    auth = resource(documents, "AuthorizationPolicy", "allow-known-sources")
    helivanta = [
        principal
        for rule in auth["spec"]["rules"]
        for source in rule.get("from", [])
        for principal in source["source"].get("principals", [])
        if "/ns/helivanta/" in principal
    ]
    assert helivanta == ["cluster.local/ns/helivanta/sa/helivanta-emergency-secret-seed", "cluster.local/ns/helivanta/sa/helivanta-pharmacy-evidence-secret-seed", "cluster.local/ns/helivanta/sa/helivanta-privacy-secret-seed", PRINCIPAL]
    for rule in auth["spec"]["rules"]:
        if any(PRINCIPAL in s["source"].get("principals", []) for s in rule.get("from", [])):
            assert rule["to"] == [{"operation": {"ports": ["8200"]}}]


def test_helivanta_egress_to_openbao_is_api_only():
    documents = render("charts/apps/helivanta-network-policies", namespace="helivanta")
    spec = resource(documents, "NetworkPolicy", "allow-helivanta-api-openbao")["spec"]
    assert spec["podSelector"] == {"matchLabels": {"app.kubernetes.io/name": "helivanta-api"}}
    assert spec["policyTypes"] == ["Egress"]
    assert spec["egress"] == [
        {
            "to": [
                {
                    "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "openbao"}},
                    "podSelector": {"matchLabels": {"app.kubernetes.io/name": "openbao"}},
                }
            ],
            "ports": [{"protocol": "TCP", "port": 8200}, {"protocol": "TCP", "port": 15008}],
        }
    ]
    others = [
        doc
        for doc in documents
        if doc["kind"] == "NetworkPolicy" and doc["metadata"]["name"] != "allow-helivanta-api-openbao"
    ]
    assert "openbao" not in json.dumps([d["spec"] for d in others])


def test_meshed_api_gets_transit_config_and_a_short_lived_token():
    pod = api(*PROD)
    container = pod["containers"][0]
    env = {e["name"]: e.get("value") for e in container["env"]}
    assert env["OPENBAO_ADDR"] == "http://openbao.openbao.svc.cluster.local:8200"
    assert env["OPENBAO_TRANSIT_MOUNT"] == "transit"
    assert env["OPENBAO_AUTH_ROLE"] == "helivanta-api-transit"
    assert env["OPENBAO_TOKEN_PATH"] == "/var/run/secrets/openbao/token"
    mount = next(m for m in container["volumeMounts"] if m["name"] == "openbao-token")
    assert mount == {"name": "openbao-token", "mountPath": "/var/run/secrets/openbao", "readOnly": True}
    volume = next(v for v in pod["volumes"] if v["name"] == "openbao-token")
    assert volume["projected"]["sources"] == [
        {"serviceAccountToken": {"path": "token", "expirationSeconds": 600}}
    ]
    assert pod.get("automountServiceAccountToken") is not True


def test_unmeshed_api_gets_no_openbao_config_and_fails_closed():
    pod = api()
    names = {e["name"] for e in pod["containers"][0]["env"]}
    assert not {n for n in names if n.startswith("OPENBAO_")}
    assert "openbao-token" not in {v["name"] for v in pod["volumes"]}
