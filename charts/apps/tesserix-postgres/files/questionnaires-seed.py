import json
import secrets
import urllib.error
import urllib.request
from pathlib import Path

BASE = 'http://openbao.openbao.svc.cluster.local:8200/v1/'

def call(path, data=None, token=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['X-Vault-Token'] = token
    req = urllib.request.Request(BASE+path, headers=headers, data=None if data is None else json.dumps(data).encode())
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.loads(response.read() or '{}')

try:
    jwt = Path('/var/run/secrets/kubernetes.io/serviceaccount/token').read_text().strip()
    token = call('auth/kubernetes/login', {'role':'questionnaires-secret-seed','jwt':jwt})['auth']['client_token']
    try:
        for name in ['writer','reader']:
            path = f'kv/data/questionnaires/prod/app/questionnaires-{name}-password'
            try:
                existing = call(path, token=token)
                assert len(existing['data']['data']['value']) >= 32
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
                call(path, {'options':{'cas':0},'data':{'value':secrets.token_urlsafe(48)}}, token)
        print('Questionnaire credential paths ready; existing values preserved')
    finally:
        call('auth/token/revoke-self', {}, token)
except Exception:
    raise SystemExit('Questionnaire secret seed failed; inspect scoped authentication and readiness (payloads withheld)') from None
