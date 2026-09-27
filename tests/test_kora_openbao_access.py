import json
import re
from test_homechef_openbao_access import render, resource

READERS = {'agentgateway-system|production': ['kora/app/kora-ai-agents-api-key',
                                    'kora/app/kora-ai-gateway-api-key',
                                    'kora/app/kora-mcp-key',
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
                     'kora/app/kora-api-platform-admin',
                     'kora/app/kora-apple-key-id',
                     'kora/app/kora-apple-private-key',
                     'kora/app/kora-apple-team-id',
                     'kora/app/kora-bff-internal-hmac-key',
                     'kora/app/kora-database-url',
                     'kora/app/kora-expo-access-token',
                     'kora/app/kora-mcp-internal-key',
                     'kora/app/kora-mcp-key',
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
