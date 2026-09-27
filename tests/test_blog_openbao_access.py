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
