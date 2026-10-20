from pathlib import Path
import re
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / 'charts/apps/document-intelligence'
# The only products allowed to call OCR, each from its own namespace.
PRODUCTS = {'devai', 'helivanta', 'homechef', 'kora', 'mark8ly', 'roamie'}
PRINCIPAL = re.compile(r'cluster\.local/ns/([a-z0-9-]+)/sa/[a-z0-9-]+')
ROUTES = ('VirtualService', 'HTTPRoute', 'GRPCRoute', 'TLSRoute', 'TCPRoute', 'Ingress', 'Gateway')


def releases():
    for values in [CHART / 'values-prod.yaml', CHART / 'values-sandbox.yaml', *sorted((CHART / 'products').glob('*.yaml'))]:
        out = subprocess.check_output(
            ['helm', 'template', 'r', str(CHART), '--namespace', 'document-intelligence', '-f', str(values)], text=True)
        yield values.name, [d for d in yaml.safe_load_all(out) if d]


def test_namespace_denies_ingress_by_default():
    policy = yaml.safe_load((ROOT / 'k8s/platform/document-intelligence/networkpolicy.yaml').read_text())
    assert policy['metadata']['namespace'] == 'document-intelligence'
    assert policy['spec']['podSelector'] == {} and policy['spec']['ingress'] == []
    assert 'Ingress' in policy['spec']['policyTypes']


def test_each_release_admits_one_listed_product_identity():
    for name, docs in releases():
        namespaces = set()
        for policy in (d for d in docs if d['kind'] == 'NetworkPolicy'):
            for rule in policy['spec'].get('ingress') or []:
                assert rule.get('from'), f'{name}: {policy["metadata"]["name"]} admits every source'
                for source in rule['from']:
                    assert list(source) == ['namespaceSelector'], (name, source)
                    labels = source['namespaceSelector']['matchLabels']
                    assert list(source['namespaceSelector']) == ['matchLabels'] and list(labels) == ['kubernetes.io/metadata.name'], (name, source)
                    namespaces.add(labels['kubernetes.io/metadata.name'])
        principals = set()
        for policy in (d for d in docs if d['kind'] == 'AuthorizationPolicy'):
            assert policy['spec'].get('action', 'ALLOW') == 'ALLOW' and policy['spec'].get('selector'), name
            for rule in policy['spec']['rules']:
                for source in rule['from']:
                    assert list(source['source']) == ['principals'], (name, source)
                    principals.update(source['source']['principals'])
        assert principals and all(PRINCIPAL.fullmatch(p) for p in principals), (name, principals)
        assert len(namespaces) == 1 and namespaces <= PRODUCTS, (name, namespaces)
        assert {PRINCIPAL.fullmatch(p).group(1) for p in principals} == namespaces, (name, principals)


def test_ocr_apis_have_no_public_route():
    for name, docs in releases():
        assert not [d['metadata']['name'] for d in docs if d['kind'] in ROUTES], name
        services = [d for d in docs if d['kind'] == 'Service']
        assert services and all(s['spec'].get('type', 'ClusterIP') == 'ClusterIP' for s in services), name
    kinds = re.compile(r'^kind:\s*(%s)\s*$' % '|'.join(ROUTES), re.M)
    routed = [
        str(p.relative_to(ROOT)) for p in ROOT.rglob('*.y*ml')
        if '.git' not in p.parts and 'document-intelligence' in (text := p.read_text(errors='ignore')) and kinds.search(text)
    ]
    assert not routed
