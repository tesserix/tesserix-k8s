import json
import re

from test_homechef_openbao_access import ROOT, render, resource

TARGETS = {
    **{
        f"prod-langfuse-{suffix}": f"langfuse/app/langfuse-{suffix}"
        for suffix in (
            "postgresql-password",
            "salt",
            "encryption-key",
            "nextauth-secret",
            "init-user-password",
            "zitadel-client-id",
            "zitadel-client-secret",
        )
    },
    **{
        f"prod-evals-langfuse-org-{suffix}": f"langfuse/app/langfuse-org-{suffix}"
        for suffix in ("public-key", "secret-key")
    },
}


def test_langfuse_access_is_exact_and_namespace_bound():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for name, sa, namespace, paths, caps in (
        (
            "read-langfuse-production",
            "langfuse-production-reader",
            "observability",
            {t for src, t in TARGETS.items() if src.startswith("prod-langfuse-")},
            ["read"],
        ),
        (
            "read-langfuse-database-production",
            "langfuse-production-reader",
            "infra",
            {TARGETS["prod-langfuse-postgresql-password"]},
            ["read"],
        ),
        (
            "read-langfuse-organization-production",
            "langfuse-production-reader",
            "evals-operator",
            {t for src, t in TARGETS.items() if src.startswith("prod-evals-")},
            ["read"],
        ),
    ):
        role = json.loads(config[f"role-{name}.json"])
        assert role["bound_service_account_names"] == [sa]
        assert role["bound_service_account_namespaces"] == [namespace]
        assert role["token_ttl"] in ("5m", "15m")
        policy = config[f"policy-{name}.hcl"]
        assert "*" not in policy
        assert set(re.findall(r'path "kv/data/([^\"]+)"', policy)) == paths
        for line in policy.splitlines():
            if 'path "kv/data/' in line:
                assert f"capabilities = {json.dumps(caps)}" in line
    assert (
        json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
            "langfuse"
        ]
        == TARGETS
    )


def test_temporary_langfuse_grant_is_removed():
    docs = render("charts/thirdparty/openbao")
    cm = resource(docs, "ConfigMap", "openbao-bootstrap")["data"]
    assert "policy-langfuse-migrate-reviewed.hcl" not in cm
    assert "role-langfuse-migrate-reviewed.json" not in cm
    assert (
        "langfuse-migration-writer"
        not in (
            ROOT / "external-secrets/prod/langfuse-openbao-readers.yaml"
        ).read_text()
    )
