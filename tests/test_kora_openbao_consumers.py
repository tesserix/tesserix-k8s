import json
from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).parents[1]

def test_all_reviewed_live_bindings_render_with_namespaced_openbao_sources():
    expected = json.loads((ROOT / 'tests/kora-consumers.json').read_text())
    owners = {c['owner'].split(':')[0] for c in expected} - {'external-secrets-resources', 'kora-secrets'}
    docs = list(yaml.safe_load_all(subprocess.check_output(['kubectl','kustomize',str(ROOT/'external-secrets/prod')],text=True)))
    docs += list(yaml.safe_load_all(subprocess.check_output(['kubectl','kustomize',str(ROOT/'external-secrets/prod/kora')],text=True)))
    for file in (ROOT/'argocd/prod').rglob('*.yaml'):
        app = yaml.safe_load(file.read_text())
        if not isinstance(app,dict) or app.get('kind')!='Application' or app['metadata']['name'] not in owners: continue
        source=app['spec']['source']; helm=source.get('helm',{}); chart=ROOT/source['path']; ns=app['spec']['destination']['namespace']
        command=['helm','template',helm.get('releaseName',app['metadata']['name']),str(chart),'--namespace',ns]
        for path in helm.get('valueFiles',[]):command+=['-f',str(chart/path)]
        command+=['-f','-']
        for p in helm.get('parameters',[]):command+=['--set-string',p['name']+'='+p['value']]
        rendered=list(yaml.safe_load_all(subprocess.check_output(command,input=yaml.safe_dump(helm.get('valuesObject',{})),text=True)))
        if app['metadata']['name'] in {'kora-api','kora-ai-agents'}:
            deployment = next(d for d in rendered if d and d.get('kind')=='Deployment')
            assert deployment['spec']['template']['metadata']['annotations']['kora.tesserix.app/secret-source'] == 'openbao-v1'
        for d in rendered:
            if d and d.get('kind')=='ExternalSecret':d['metadata'].setdefault('namespace',ns);docs.append(d)
    for c in expected:
        secret=next(d for d in docs if d and d.get('kind')=='ExternalSecret' and d['metadata'].get('namespace')==c['namespace'] and d['metadata']['name']==c['name'])
        entry=next(d for d in secret['spec']['data'] if d['secretKey']==c['key'])
        source=c['source'];dev=source.startswith('dev-');name=source.removeprefix('prod-').removeprefix('dev-').replace('agentic-registry-kora-','kora-registry-').replace('support-platform-kora-','kora-')
        assert entry['remoteRef']=={'key':('kora-development' if dev else 'kora')+'/app/'+name,'property':'value'},c
        assert entry.get('sourceRef',{}).get('storeRef',secret['spec']['secretStoreRef'])=={'name':'openbao-kora-'+('development' if dev else 'production'),'kind':'SecretStore'},c
