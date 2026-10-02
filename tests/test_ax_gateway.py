from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
PRINCIPALS = {'cluster.local/ns/ax-system/sa/ax-server', 'cluster.local/ns/ax-system/sa/atenet-egress'}


def test_gateway_admits_only_named_ax_runtime_identities():
    values = yaml.safe_load((ROOT / 'charts/apps/devai-ai-gateway/values.yaml').read_text())
    assert PRINCIPALS <= set(values['authorizationPolicy']['axPrincipals'])
    docs = list(yaml.safe_load_all((ROOT / 'manifests/agentic-istio/authorization-policy.yaml').read_text()))
    for name, field in [('ai-gateway-authz', 'principals'), ('ai-gateway-deny-non-devai', 'notPrincipals')]:
        obj = next(d for d in docs if d and d['metadata']['name'] == name)
        assert any(PRINCIPALS <= set(rule['from'][0]['source'].get(field, [])) for rule in obj['spec']['rules'] if 'from' in rule)
    allow = next(d for d in docs if d and d['metadata']['name'] == 'ai-gateway-authz')
    rule = next(r for r in allow['spec']['rules'] if 'from' in r and PRINCIPALS <= set(r['from'][0]['source'].get('principals', [])))
    assert rule['to'][0]['operation']['paths'] == ['/vertex/*']
    deny = next(d for d in docs if d and d['metadata']['name'] == 'ai-gateway-deny-ax-non-vertex')
    assert deny['spec']['rules'][0]['to'][0]['operation']['notPaths'] == ['/vertex/*']
    assert not PRINCIPALS.intersection(values['authorizationPolicy']['allowedPrincipals'])


def test_ax_model_clients_are_enrolled_in_ambient_mesh():
    for name in ('ax-server', 'atenet-egress'):
        docs = list(yaml.safe_load_all((ROOT / f'argocd/prod/apps/ax/runtime/{name}.yaml').read_text()))
        deployment = next(d for d in docs if d and d['kind'] == 'Deployment')
        assert deployment['spec']['template']['metadata']['labels']['istio.io/dataplane-mode'] == 'ambient'


def test_actor_tunnel_keeps_native_mtls_under_ambient():
    policy_path = ROOT / 'argocd/prod/apps/ax/runtime/egress-peer-authentication.yaml'
    policy = yaml.safe_load(policy_path.read_text())
    assert policy['spec']['selector']['matchLabels'] == {'app': 'atenet-egress'}
    assert policy['spec']['mtls']['mode'] == 'STRICT'
    assert policy['spec']['portLevelMtls'] == {443: {'mode': 'DISABLE'}}
    egress = (ROOT / 'argocd/prod/apps/ax/runtime/atenet-egress.yaml').read_text()
    assert 'require_client_certificate: true' in egress
