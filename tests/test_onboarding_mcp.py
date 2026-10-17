import json
import pathlib
import subprocess
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


class OnboardingMCPContract(unittest.TestCase):
    def test_private_api_enables_dedicated_gateway_verification(self):
        output = subprocess.check_output([
            'helm', 'template', 'onboarding', 'charts/apps/onboarding-service',
            '-f', 'charts/apps/onboarding-service/values-prod.yaml',
        ], cwd=ROOT, text=True)
        docs = list(yaml.safe_load_all(output))
        deployment = next(d for d in docs if d and d['kind'] == 'Deployment')
        env = {e['name']: e.get('value') for e in deployment['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(env.get('MCP_GATEWAY_PROJECT_ID'), '387190457387450503')
        ingress = next(d for d in docs if d and d['kind'] == 'NetworkPolicy' and d['metadata']['name'] == 'allow-onboarding-mcp-gateway')
        source = ingress['spec']['ingress'][0]['from'][0]
        self.assertEqual(source['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name'], 'agentgateway-system')
        self.assertEqual(source['podSelector']['matchLabels']['app.kubernetes.io/name'], 'agentgateway-mcp')
        self.assertEqual(ingress['spec']['ingress'][0]['ports'], [{'protocol': 'TCP', 'port': 8080}])

    def test_agent_has_no_adoption_or_platform_administration(self):
        values = yaml.safe_load((ROOT / 'charts/apps/zitadel-bootstrap/values.yaml').read_text())
        projects = values['desired']['platformProjects']
        gateway = next(p for p in projects if p['name'] == 'AgentGateway')
        grant = next(g for g in gateway['machineGrants'] if g['login'] == 'onboarding-mcp-claude-prod')
        self.assertEqual(set(grant['roles']), {'agentgateway.mcp', 'onboarding.helivanta.read', 'onboarding.helivanta.create'})

    def test_registry_uses_original_caller_and_stateless_private_endpoint(self):
        manifest = list(yaml.safe_load_all((ROOT / 'charts/apps/agentgateway-route-sync/files/onboarding/registry.yaml').read_text()))
        server = next(d for d in manifest if d['kind'] == 'MCPServer')
        self.assertEqual(server['spec']['endpoint'], 'http://onboarding-api.onboarding.svc.cluster.local:8080/mcp')
        self.assertNotIn('credentialRef', server['spec'])
        self.assertEqual(server['metadata']['visibility'], 'internal')
        self.assertEqual(server['spec']['protocolVersion'], '2026-07-28')
        tools = [d for d in manifest if d['kind'] == 'Tool']
        self.assertEqual(len(tools), 5)
        for tool in tools:
            self.assertFalse(tool['spec']['inputSchema']['additionalProperties'])
            self.assertFalse(tool['spec']['outputSchema']['additionalProperties'])

    def test_openbao_reader_is_exact_and_namespace_bound(self):
        values = yaml.safe_load((ROOT / 'charts/thirdparty/openbao/values.yaml').read_text())
        policy = next(p for p in values['bootstrap']['policies'] if p['name'] == 'onboarding-mcp-client-reader')
        self.assertIn('kv/data/onboarding/prod/app/onboarding-mcp-claude-prod', policy['hcl'])
        self.assertNotIn('*', policy['hcl'])
        self.assertNotIn('update', policy['hcl'])
        roles = values['bootstrap']['kubernetesRoles']
        role = next(r for r in roles if r['name'] == 'onboarding-mcp-client-reader')
        self.assertEqual(role['namespaces'], ['onboarding'])
        self.assertEqual(role['serviceAccounts'], ['onboarding-mcp-client'])


if __name__ == '__main__':
    unittest.main()
