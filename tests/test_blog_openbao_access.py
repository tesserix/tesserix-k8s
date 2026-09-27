import json
import re

from test_homechef_openbao_access import render, resource

READERS = {
    "tesserix-production": ["mongodb-uri", "session-secret", "oidc-client-secret"],
    "tesserix-legacy": ["keycloak-client-secret"],
    "mongodb-blog-production": ["mongodb-root-password"],
    "db-backup-and-restore-production": ["mongodb-root-password"],
}


def test_blog_readers_cannot_write_or_read_other_products():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for reader, suffixes in READERS.items():
        namespace, environment = reader.rsplit("-", 1)
        name = "read-blog-" + reader
        role = json.loads(config["role-" + name + ".json"])
        assert role["bound_service_account_namespaces"] == [namespace]
        assert role["bound_service_account_names"] == [
            "blog-" + environment + "-reader"
        ]
        assert role["token_policies"] == [name]
        policy = config["policy-" + name + ".hcl"]
        assert set(re.findall(r'path "([^"]+)"', policy)) == {
            "kv/data/blog/app/blog-" + suffix for suffix in suffixes
        }
        assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}


def test_blog_migration_writer_is_not_a_persistent_grant():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    assert "policy-blog-migrate-reviewed.hcl" not in config
    assert "role-blog-migrate-reviewed.json" not in config
    import yaml
    from pathlib import Path

    docs = list(
        yaml.safe_load_all(
            (
                Path(__file__).parents[1]
                / "external-secrets/prod/blog-openbao-readers.yaml"
            ).read_text()
        )
    )
    assert all(d["metadata"]["name"] != "blog-migration-writer" for d in docs if d)
