import yaml
from test_homechef_openbao_access import ROOT, render, resource


def test_langfuse_service_and_database_use_namespace_bound_openbao():
    app = yaml.safe_load(
        (ROOT / "external-secrets/prod/observability/langfuse-secrets.yaml").read_text()
    )
    assert app["spec"]["secretStoreRef"] == {
        "name": "openbao-langfuse-production",
        "kind": "SecretStore",
    }
    entries = {entry["secretKey"]: entry for entry in app["spec"]["data"]}
    for key, suffix in {
        "postgres-password": "postgresql-password",
        "salt": "salt",
        "encryption-key": "encryption-key",
        "nextauth-secret": "nextauth-secret",
        "init-user-password": "init-user-password",
        "zitadel-client-id": "zitadel-client-id",
        "zitadel-client-secret": "zitadel-client-secret",
    }.items():
        assert entries[key]["remoteRef"] == {
            "key": "langfuse/app/langfuse-" + suffix,
            "property": "value",
        }
    assert entries["clickhouse-password"]["sourceRef"]["storeRef"] == {
        "name": "gcp-secret-store",
        "kind": "ClusterSecretStore",
    }
    database = resource(
        render("charts/apps/infra-postgres"),
        "ExternalSecret",
        "infra-postgres-langfuse",
    )
    assert database["spec"]["secretStoreRef"] == app["spec"]["secretStoreRef"]
    assert database["spec"]["data"] == [
        {
            "secretKey": "password",
            "remoteRef": {
                "key": "langfuse/app/langfuse-postgresql-password",
                "property": "value",
            },
        }
    ]
    assert (
        database["spec"]["target"]["template"]["metadata"]["labels"]["cnpg.io/reload"]
        == "true"
    )


def test_failed_org_credentials_are_not_cut_over():
    docs = list(
        yaml.safe_load_all(
            (ROOT / "k8s/operators/evals-onboarding/resources.yaml").read_text()
        )
    )
    es = resource(docs, "ExternalSecret", "langfuse-org-credentials")
    assert es["spec"]["secretStoreRef"] == {
        "name": "gcp-secret-store",
        "kind": "ClusterSecretStore",
    }
