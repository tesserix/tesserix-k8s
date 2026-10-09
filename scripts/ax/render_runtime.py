"""Render the pinned, patched Substrate sources into the AX GitOps overlay."""
import argparse
import copy
import json
from pathlib import Path

import yaml
from harden_runtime import harden

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'argocd/prod/apps/ax/runtime'
NS = 'ax-system'

class Dumper(yaml.SafeDumper):
    pass

def literal(dumper, value):
    return dumper.represent_scalar('tag:yaml.org,2002:str', value, style='|' if '\n' in value else None)

Dumper.add_representer(str, literal)

def dump(path, docs):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('# Derived from Apache-2.0 licensed Google Agent Substrate; see scripts/ax/README.md.\n' + yaml.dump_all(docs, Dumper=Dumper, sort_keys=False))

def walk(value, images):
    if isinstance(value, list):
        return [walk(v, images) for v in value]
    if isinstance(value, dict):
        result = {k: walk(v, images) for k, v in value.items()}
        if result.get('image', '').startswith('ko://'):
            result['image'] = images[result['image'].rsplit('/', 1)[-1]]
        if 'secretName' in result:
            result['secretName'] = secret_name(result['secretName'])
        for key in ('secret', 'secretRef'):
            if isinstance(result.get(key), dict) and 'name' in result[key]:
                result[key]['name'] = secret_name(result[key]['name'])
        return result
    return value

def secret_name(name):
    if name == 'actor-id-ca-certs':
        return 'ax-actor-id-ca'
    if name == 'postgres-server-ca':
        return 'ax-postgres-ca'
    return name if name.startswith('ax-') else 'ax-' + name

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    images = json.loads((ROOT / 'scripts/ax/images.json').read_text())
    base = args.source / 'manifests/ate-install'
    paths = ['ate-api-server.yaml', 'ate-controller.yaml', 'atelet.yaml', 'atenet-router.yaml', 'atenet-egress.yaml', 'pod-certificate-controller.yaml', 'generated/role.yaml', 'sandboxconfig-gvisor.yaml']
    paths += [str(p.relative_to(base)) for p in sorted((base / 'generated').glob('*_*.yaml'))]
    files = []
    for path in paths:
        output = []
        for obj in yaml.safe_load_all((base / path).read_text().replace('${SUBSTRATE_VERSION_SUFFIX}', 'ax944abe').replace('${SUBSTRATE_VERSION}', 'ax944abe')):
            if not obj or obj['kind'] in ('Namespace', 'PodDisruptionBudget'):
                continue
            obj = walk(obj, images)
            kind = obj['kind']
            meta = obj['metadata']
            if 'namespace' in meta:
                meta['namespace'] = NS
            if kind in ('ClusterRole', 'ClusterRoleBinding', 'PriorityClass'):
                meta['name'] = 'ax-' + meta['name']
            if 'roleRef' in obj and obj['roleRef']['kind'] == 'ClusterRole':
                obj['roleRef']['name'] = 'ax-' + obj['roleRef']['name']
            for subject in obj.get('subjects', []):
                if subject.get('kind') == 'ServiceAccount':
                    if subject.get('namespace') == 'podcertificate-controller-system' and subject['name'] == 'default':
                        subject['name'] = 'ax-podcert'
                    subject['namespace'] = NS
            wave = '-7' if kind == 'CustomResourceDefinition' else '-6' if kind in ('ServiceAccount','ClusterRole','ClusterRoleBinding','Role','RoleBinding','PriorityClass','ConfigMap') else '-3' if kind == 'SandboxConfig' else '0'
            meta.setdefault('annotations', {})['argocd.argoproj.io/sync-wave'] = wave
            if kind == 'Service':
                obj['spec']['type'] = 'ClusterIP'
                for key in ('externalTrafficPolicy','loadBalancerIP','loadBalancerSourceRanges'):
                    obj['spec'].pop(key, None)
                for port in obj['spec'].get('ports', []):
                    port.pop('nodePort', None)
            if kind == 'PriorityClass':
                obj['value'] = 1000
            if kind == 'ConfigMap' and 'envoy.yaml' in obj.get('data', {}):
                obj['data']['envoy.yaml'] = obj['data']['envoy.yaml'].replace('podcertificate-controller-system', NS)
            if kind in ('Deployment', 'DaemonSet'):
                template = obj['spec']['template']
                labels = template['metadata'].setdefault('labels', {})
                labels['ax.tesserix.app/component'] = meta['name']
                if meta['name'] == 'atenet-egress':
                    labels['istio.io/dataplane-mode'] = 'ambient'
                spec = template['spec']
                if meta['name'] == 'podcertificate-controller':
                    spec['serviceAccountName'] = 'ax-podcert'
                spec['automountServiceAccountToken'] = True
                if kind == 'DaemonSet':
                    spec['nodeSelector'] = {'cloud.google.com/gke-nodepool': 'optimized-v2'}
                    spec['priorityClassName'] = 'atelet-nonpreempting'
                    spec['affinity'] = {'nodeAffinity': {'requiredDuringSchedulingIgnoredDuringExecution': {'nodeSelectorTerms': [{'matchExpressions': [{'key': 'topology.kubernetes.io/zone', 'operator': 'In', 'values': ['asia-south1-b', 'asia-south1-c']}]}]}}}
                    spec.setdefault('volumes', []).append({'name': 'runtime-tmp', 'emptyDir': {'sizeLimit': '512Mi'}})
                if 'priorityClassName' in spec:
                    spec['priorityClassName'] = 'ax-' + spec['priorityClassName']
                if kind == 'Deployment':
                    obj['spec']['replicas'] = 2 if meta['name'] in ('ate-api-server','atenet-router','atenet-egress') else 1
                    spec['affinity'] = {'podAntiAffinity': {'requiredDuringSchedulingIgnoredDuringExecution': [{'labelSelector': {'matchLabels': obj['spec']['selector']['matchLabels']}, 'topologyKey': 'kubernetes.io/hostname'}]}}
                for c in spec['containers']:
                    c.setdefault('resources', {'requests': {'cpu': '50m', 'memory': '128Mi'}, 'limits': {'memory': '512Mi'}})
                    c.setdefault('resources', {}).setdefault('limits', {'memory': '512Mi'})
                    if meta['name'].startswith('atelet-'):
                        c['resources'] = {'requests': {'cpu': '50m', 'memory': '128Mi'}, 'limits': {'memory': '1Gi', 'cpu': '1'}}
                        c.setdefault('securityContext', {})['readOnlyRootFilesystem'] = True
                        c.setdefault('volumeMounts', []).append({'name': 'runtime-tmp', 'mountPath': '/tmp'})
                    if meta['name'] == 'ate-api-server':
                        c['args'].append('--egress-gateway-address=atenet-egress.ax-system.svc:443')
                        for ref in c.get('envFrom', []):
                            if 'secretRef' in ref:
                                ref['secretRef'].pop('optional', None)
                    if c.get('securityContext', {}).get('privileged') is not True and c['name'] != 'envoy':
                        c.setdefault('securityContext', {}).update({'allowPrivilegeEscalation': False, 'capabilities': {'drop': ['ALL']}})
                if kind == 'Deployment' and obj['spec']['replicas'] > 1:
                    output.append({'apiVersion':'policy/v1','kind':'PodDisruptionBudget','metadata':{'name':meta['name'],'namespace':NS},'spec':{'maxUnavailable':1,'selector':obj['spec']['selector']}})
            output.append(obj)
            if kind == 'PriorityClass':
                priority = copy.deepcopy(obj)
                priority['metadata']['name'] = 'ax-atelet-nonpreempting'
                priority['preemptionPolicy'] = 'Never'
                output.append(priority)
        name = Path(path).name.replace('ate.dev_', 'ax.ate.dev_')
        dump(OUT / name, output)
        files.append(name)
    # Keep native deployment/network mutations and the one CA read namespace-bound.
    path = OUT / 'role.yaml'
    objects = list(yaml.safe_load_all(path.read_text()))
    cluster = next(o for o in objects if o['kind'] == 'ClusterRole')
    role = next(o for o in objects if o['kind'] == 'Role')
    keep = []
    for rule in cluster['rules']:
        if rule['apiGroups'] in (['apps'], ['networking.k8s.io']):
            role['rules'].append(rule)
        elif 'secrets' in rule['resources']:
            rule['resources'].remove('secrets')
            keep.append(rule)
            role['rules'].append({'apiGroups':[''],'resources':['secrets'],'resourceNames':['ax-egress-mitm-ca-pool'],'verbs':['get','list','watch']})
        else:
            keep.append(rule)
    cluster['rules'] = keep
    dump(path, objects)
    dump(OUT / 'kustomization.yaml', [{'apiVersion':'kustomize.config.k8s.io/v1beta1','kind':'Kustomization','resources':sorted({*files, *(p.name for p in OUT.glob('*.yaml') if p.name != 'kustomization.yaml')})}])

if __name__ == '__main__':
    main()

harden(OUT)
