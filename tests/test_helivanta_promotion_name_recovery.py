from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]


def recovery_resources(enabled=True):
    command = ['helm', 'template', 'helivanta-growthbook-recovery', 'charts/infrastructure/helivanta-growthbook-recovery', '--namespace', 'argocd']
    if enabled is not None:
        command += ['--set', f'enabled={str(enabled).lower()}']
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=True)
    return [doc for doc in yaml.safe_load_all(result.stdout) if doc]


def test_repair_matches_only_the_approved_record_and_recovery_actor():
    policy = next(doc for doc in recovery_resources() if doc['kind'] == 'MutatingAdmissionPolicy')
    spec = policy['spec']
    assert spec['failurePolicy'] == 'Fail'
    assert spec['reinvocationPolicy'] == 'Never'
    assert spec['matchConstraints']['namespaceSelector']['matchLabels'] == {'kubernetes.io/metadata.name': 'kargo-infra'}
    rule = spec['matchConstraints']['resourceRules'][0]
    assert rule == {'apiGroups': ['kargo.akuity.io'], 'apiVersions': ['v1alpha1'], 'resources': ['promotions'], 'resourceNames': ['helivanta-growthbook-bootstrap-d5a84e8-sync-1794831055'], 'operations': ['UPDATE'], 'scope': 'Namespaced'}
    conditions = {item['name']: item['expression'] for item in spec['matchConditions']}
    assert conditions['recovery-actor'] == "request.userInfo.username == 'system:serviceaccount:kargo-infra:helivanta-growthbook-promotion-recovery'"
    assert "oldObject.metadata.name == 'helivanta-growthbook-prod.01m7j491cvmf8n1jk9px5cdzra.8006e04'" in conditions['archived-object']
    assert "oldObject.spec.stage == 'helivanta-growthbook-prod'" in conditions['archived-object']


def test_mutation_only_restores_the_existing_immutable_name():
    docs = recovery_resources()
    policy = next(doc for doc in docs if doc['kind'] == 'MutatingAdmissionPolicy')
    assert policy['spec']['mutations'] == [{'patchType': 'JSONPatch', 'jsonPatch': {'expression': '[JSONPatch{op: "replace", path: "/metadata/name", value: oldObject.metadata.name}]'}}]
    binding = next(doc for doc in docs if doc['kind'] == 'MutatingAdmissionPolicyBinding')
    assert binding['spec']['policyName'] == policy['metadata']['name']
    assert binding['spec']['matchResources']['namespaceSelector']['matchLabels'] == {'kubernetes.io/metadata.name': 'kargo-infra'}
    assert len(docs) == 2


def test_completed_recovery_renders_no_admission_exception_by_default():
    assert recovery_resources(enabled=None) == []
