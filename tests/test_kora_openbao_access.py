import json
import re
from test_homechef_openbao_access import render, resource

READERS = {'agentgateway-system|production': ['kora/app/kora-ai-agents-api-key',
                                    'kora/app/kora-ai-gateway-api-key',
                                    'kora/app/kora-mcp-key',
                                    'kora/app/kora-typesafe-api-key',
                                    'kora/app/kora-vertex-api-key'],
 'agentregistry-system|production': ['kora/app/kora-registry-deploy-key-sha256'],
 'devai|development': ['kora-development/app/kora-document-intelligence-signing-key',
                       'kora-development/app/kora-langfuse-public-key',
                       'kora-development/app/kora-langfuse-secret-key'],
 'document-intelligence|development': ['kora-development/app/kora-ocr-workload-identity-keys'],
 'document-intelligence|production': ['kora/app/kora-ocr-workload-identity-keys'],
 'global|production': ['kora/app/kora-postgresql-password'],
 'kora|production': ['kora/app/kora-ai-agents-api-key',
                     'kora/app/kora-ai-gateway-api-key',
                     'kora/app/kora-ai-trace-user-key',
                     'kora/app/kora-api-platform-admin',
                     'kora/app/kora-apple-key-id',
                     'kora/app/kora-apple-private-key',
                     'kora/app/kora-apple-team-id',
                     'kora/app/kora-bff-internal-hmac-key',
                     'kora/app/kora-database-url',
                     'kora/app/kora-eval-email',
                     'kora/app/kora-eval-firebase-api-key',
                     'kora/app/kora-eval-password',
                     'kora/app/kora-expo-access-token',
                     'kora/app/kora-langfuse-public-key',
                     'kora/app/kora-langfuse-secret-key',
                     'kora/app/kora-mcp-internal-key',
                     'kora/app/kora-mcp-key',
                     'kora/app/kora-ocr-workload-identity-keys',
                     'kora/app/kora-registry-deploy-key',
                     'kora/app/kora-sandbox-anonymization-salt',
                     'kora/app/kora-sandbox-reader-password',
                     'kora/app/kora-sandbox-sync-source-url',
                     'kora/app/kora-sandbox-sync-target-url'],
 'observability|development': ['kora-development/app/kora-langfuse-public-key',
                               'kora-development/app/kora-langfuse-secret-key'],
 'observability|production': ['kora/app/kora-langfuse-public-key',
                              'kora/app/kora-langfuse-secret-key'],
 'tesserix|production': ['kora/app/kora-api-platform-admin',
                         'kora/app/kora-bff-internal-hmac-key']}

def test_kora_readers_are_exact_path_read_only_and_namespace_bound():
    config = resource(render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap")["data"]
    for reader, paths in READERS.items():
        namespace, environment = reader.split("|")
        name = "read-kora-" + namespace + "-" + environment
        role = json.loads(config["role-" + name + ".json"])
        assert role["bound_service_account_namespaces"] == [namespace]
        assert role["bound_service_account_names"] == ["kora-" + environment + "-reader"]
        assert role["token_policies"] == [name]
        policy = config["policy-" + name + ".hcl"]
        assert set(re.findall(r'path "([^"]+)"', policy)) == {"kv/data/" + p for p in paths}
        assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}


def test_kora_producer_and_console_have_disjoint_exact_permissions():
    config = resource(render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap")["data"]
    writer = config["policy-evals-onboarding-writer.hcl"]
    assert set(re.findall(r'path "([^"]+)"', writer)) == {
        "kv/data/kora/app/kora-langfuse-public-key",
        "kv/data/kora/app/kora-langfuse-secret-key",
        "kv/data/devai/app/devai-langfuse-public-key",
        "kv/data/devai/app/devai-langfuse-secret-key",
        "auth/token/revoke-self",
    }
    metadata = config["policy-company-kora-key-metadata.hcl"]
    assert "kv/data/" not in metadata
    assert set(re.findall(r'path "([^"]+)"', metadata)) == {
        "kv/metadata/kora/app/kora-gemini-api-key",
        "kv/metadata/kora/app/kora-openai-api-key",
        "auth/token/revoke-self",
    }
    assert not any("kora-migrate-reviewed" in key for key in config)
    for name, namespace, account in [
        ("company-kora-key-metadata", "tesserix", "company"),
        ("evals-onboarding-writer", "evals-operator", "evals-onboarding-operator"),
    ]:
        role = json.loads(config["role-" + name + ".json"])
        assert role["bound_service_account_namespaces"] == [namespace]
        assert role["bound_service_account_names"] == [account]
        assert role["token_policies"] == [name]


def test_kora_operator_and_metadata_reader_have_scoped_network_access():
    import pathlib
    import subprocess
    import yaml
    root = pathlib.Path(__file__).parents[1]
    docs = render("charts/apps/openbao-namespace")
    ingress = resource(docs, "NetworkPolicy", "allow-clients-to-openbao")
    peers = ingress["spec"]["ingress"][0]["from"]
    for namespace, app in [("evals-operator", "evals-onboarding-operator"), ("tesserix", "company")]:
        assert {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": namespace}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": app}}} in peers
    operator = list(yaml.safe_load_all((root/"k8s/operators/evals-onboarding/resources.yaml").read_text()))
    policy = resource(operator, "NetworkPolicy", "evals-onboarding-operator")
    assert any(rule.get("ports") == [{"protocol": "TCP", "port": 8200}] for rule in policy["spec"]["egress"])
