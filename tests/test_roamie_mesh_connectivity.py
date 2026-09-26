from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
FILE = ROOT / 'manifests/agentic-istio/roamie-runtime-connectivity.yaml'


def test_roamie_mesh_paths_have_bidirectional_namespace_policies():
    resources = {d['metadata']['name']: d for d in yaml.safe_load_all(FILE.read_text())}
    for name, namespace, direction, peer in (
        ('roamie-gateway-egress', 'agentgateway-system', 'egress', 'roamie'),
        ('roamie-runtime-egress', 'roamie', 'egress', 'agentgateway-system'),
        ('roamie-runtime-ingress', 'roamie', 'ingress', 'agentgateway-system'),
        ('roamie-gateway-ingress', 'agentgateway-system', 'ingress', 'roamie'),
        ('roamie-registry-egress', 'roamie', 'egress', 'agentregistry-system'),
        ('roamie-registry-ingress', 'agentregistry-system', 'ingress', 'roamie'),
    ):
        resource = resources[name]
        assert resource['metadata']['namespace'] == namespace
        rules = resource['spec'][direction]
        assert any(
            p['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name'] == peer
            for r in rules for p in r['to' if direction == 'egress' else 'from']
        )
        assert all('ports' not in r for r in rules)  # ambient HBONE
    registry = resources['roamie-registry-read']['spec']
    assert registry['rules'][0]['from'][0]['source']['principals'] == ['cluster.local/ns/roamie/sa/roamie-trip-manager']
    assert registry['rules'][0]['to'][0]['operation']['methods'] == ['GET']
    assert 'roamie-runtime-connectivity.yaml' in yaml.safe_load((FILE.parent/'kustomization.yaml').read_text())['resources']
