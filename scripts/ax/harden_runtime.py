"""Apply reviewed pod defaults to generated and authored AX resources."""
from pathlib import Path
import yaml


def harden(directory: Path) -> None:
    for path in directory.glob('*.yaml'):
        docs = list(yaml.safe_load_all(path.read_text()))
        for obj in docs:
            if not obj or obj['kind'] not in ('Deployment', 'Job', 'CronJob'):
                continue
            job = obj['spec']['jobTemplate']['spec'] if obj['kind'] == 'CronJob' else obj['spec']
            spec = job['template']['spec']
            spec.setdefault('securityContext', {}).update({
                'runAsNonRoot': True, 'runAsUser': 65532, 'runAsGroup': 65532,
                'fsGroup': 65532, 'seccompProfile': {'type': 'RuntimeDefault'},
            })
            if obj['kind'] == 'Deployment':
                spec['securityContext']['sysctls'] = [{'name': 'net.ipv4.ip_unprivileged_port_start', 'value': '0'}]
            volumes = spec.setdefault('volumes', [])
            if not any(v['name'] == 'runtime-tmp' for v in volumes):
                volumes.append({'name': 'runtime-tmp', 'emptyDir': {'sizeLimit': '256Mi'}})
            for c in spec.get('containers', []) + spec.get('initContainers', []):
                c.setdefault('securityContext', {}).update({
                    'allowPrivilegeEscalation': False, 'readOnlyRootFilesystem': True,
                    'runAsNonRoot': True, 'runAsUser': 65532, 'runAsGroup': 65532,
                    'capabilities': {'drop': ['ALL']},
                })
                mounts = c.setdefault('volumeMounts', [])
                if not any(m['mountPath'] == '/tmp' for m in mounts):
                    mounts.append({'name': 'runtime-tmp', 'mountPath': '/tmp'})
                c.setdefault('resources', {}).setdefault('limits', {})['cpu'] = '1'
                if c['name'] == 'upload':
                    env = c.setdefault('env', [])
                    if not any(e['name'] == 'CLOUDSDK_CONFIG' for e in env):
                        env.append({'name': 'CLOUDSDK_CONFIG', 'value': '/tmp/gcloud'})
        path.write_text(yaml.safe_dump_all(docs, sort_keys=False))


if __name__ == '__main__':
    harden(Path(__file__).resolve().parents[2] / 'argocd/prod/apps/ax/runtime')
