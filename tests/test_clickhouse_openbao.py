import json
import re

import yaml
from test_homechef_openbao_access import ROOT, render, resource

TARGETS = {
    f"prod-clickhouse-{s}": f"clickhouse/app/clickhouse-{s}"
    for s in ("otel-password", "observer-password", "sre-writer-password")
}


def test_clickhouse_namespace_readers_have_only_needed_paths():
    cm = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for ns, paths in [
        ("observability", set(TARGETS.values())),
        ("tesserix", {TARGETS["prod-clickhouse-otel-password"]}),
    ]:
        name = f"read-clickhouse-{ns}-production"
        role = json.loads(cm[f"role-{name}.json"])
        assert role["bound_service_account_names"] == ["clickhouse-production-reader"]
        assert role["bound_service_account_namespaces"] == [ns]
        policy = cm[f"policy-{name}.hcl"]
        assert "*" not in policy
        assert set(re.findall(r'path "kv/data/([^\"]+)"', policy)) == paths
        assert all(
            'capabilities = ["read"]' in line
            for line in policy.splitlines()
            if 'path "kv/data/' in line
        )


def test_all_clickhouse_consumers_use_same_reviewed_values():
    store = {"name": "openbao-clickhouse-production", "kind": "SecretStore"}
    es = yaml.safe_load(
        (
            ROOT / "external-secrets/prod/observability/clickhouse-secrets.yaml"
        ).read_text()
    )
    assert es["spec"]["secretStoreRef"] == store
    assert es["spec"]["refreshInterval"] == "5m"
    assert {x["remoteRef"]["key"] for x in es["spec"]["data"]} == set(TARGETS.values())
    assert all(x["remoteRef"]["property"] == "value" for x in es["spec"]["data"])
    langfuse = yaml.safe_load(
        (ROOT / "external-secrets/prod/observability/langfuse-secrets.yaml").read_text()
    )
    ch = next(
        x for x in langfuse["spec"]["data"] if x["secretKey"] == "clickhouse-password"
    )
    assert ch["remoteRef"] == {
        "key": TARGETS["prod-clickhouse-otel-password"],
        "property": "value",
    }
    assert ch["sourceRef"]["storeRef"] == store
    company = resource(
        list(
            filter(
                None,
                yaml.safe_load_all(
                    (
                        ROOT / "external-secrets/prod/tesserix/externalsecret.yaml"
                    ).read_text()
                ),
            )
        ),
        "ExternalSecret",
        "tesserix-clickhouse-otel",
    )
    assert company["spec"]["secretStoreRef"] == store
    assert company["spec"]["refreshInterval"] == "5m"
    assert company["spec"]["data"][0]["remoteRef"] == ch["remoteRef"]
