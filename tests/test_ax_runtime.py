from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'argocd/prod/apps/ax/runtime'


def objects():
    files = list(RUNTIME.glob('*.yaml'))
    assert files, 'AX runtime manifests must exist'
    return [obj for path in files for obj in yaml.safe_load_all(path.read_text()) if obj]


def test_runtime_does_not_claim_legacy_objects_or_host_ports():
    for obj in objects():
        meta = obj.get('metadata', {})
        assert meta.get('namespace', 'ax-system') in ('ax-system', 'global')
        if obj['kind'] in ('ClusterRole', 'ClusterRoleBinding', 'PriorityClass'):
            assert meta['name'].startswith('ax-')
        if obj['kind'] == 'CustomResourceDefinition':
            assert obj['spec']['group'] == 'ax.ate.dev'
        spec = obj.get('spec', {}).get('template', {}).get('spec', {})
        for volume in spec.get('volumes', []):
            assert volume.get('hostPath', {}).get('path') != '/var/lib/ateom-gvisor'
        for container in spec.get('containers', []):
            for port in container.get('ports', []):
                assert port.get('hostPort') not in (8085, 9090)
        for rule in obj.get('rules', []):
            assert 'ate.dev' not in rule.get('apiGroups', [])


def test_ax_gitops_is_registered_and_private():
    app = yaml.safe_load((ROOT / 'argocd/prod/infrastructure/ax.yaml').read_text())
    parent = yaml.safe_load((ROOT / 'argocd/prod/infrastructure/kustomization.yaml').read_text())
    assert 'ax.yaml' in parent['resources']
    assert app['spec']['destination']['namespace'] == 'ax-system'
    for obj in objects():
        assert obj['kind'] not in ('Ingress', 'Gateway', 'HTTPRoute')
        if obj['kind'] == 'Service':
            assert obj['spec'].get('type', 'ClusterIP') == 'ClusterIP'


def test_runtime_is_rendered_unique_and_memory_bounded():
    identities = set()
    for obj in objects():
        if obj['kind'] == 'Kustomization':
            continue
        identity = (obj['apiVersion'], obj['kind'], obj['metadata'].get('namespace'), obj['metadata']['name'])
        assert identity not in identities, identity
        identities.add(identity)
        assert '${SUBSTRATE_VERSION' not in yaml.safe_dump(obj)
        spec = obj.get('spec', {}).get('template', {}).get('spec', {})
        for c in spec.get('containers', []):
            assert '@sha256:' in c['image']
            assert c['resources']['limits']['memory']


def test_control_plane_runs_nonroot_with_seccomp_and_readonly_root():
    for obj in objects():
        if obj['kind'] != 'Deployment':
            continue
        spec = obj['spec']['template']['spec']
        assert spec['securityContext']['runAsNonRoot'] is True
        assert spec['securityContext']['seccompProfile']['type'] == 'RuntimeDefault'
        for c in spec['containers']:
            assert c['securityContext']['readOnlyRootFilesystem'] is True
            assert c['securityContext']['allowPrivilegeEscalation'] is False
            assert c['securityContext']['capabilities']['drop'] == ['ALL']


def test_bootstrap_has_scoped_openbao_network_access_and_retry_hook():
    values = yaml.safe_load((ROOT / 'charts/apps/openbao-namespace/values.yaml').read_text())
    matches = [x for x in values['allowedPodSources'] if x['namespace'] == 'ax-system']
    assert matches == [{'namespace': 'ax-system', 'podLabels': {'app': 'ax-secret-bootstrap'}}]
    assert 'ax-system' not in values['allowedSources']
    job = next(o for o in objects() if o['kind'] == 'Job' and o['metadata']['name'] == 'ax-secret-bootstrap')
    assert job['metadata']['annotations']['argocd.argoproj.io/hook'] == 'Sync'
