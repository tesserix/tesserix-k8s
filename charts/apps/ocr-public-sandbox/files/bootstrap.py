import json
import secrets
import urllib.error
import urllib.request

BASE = 'http://openbao.openbao.svc.cluster.local:8200/v1/'
token = ''

def request(path, body=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['X-Vault-Token'] = token
    req = urllib.request.Request(BASE + path, data=None if body is None else json.dumps(body).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return json.loads(response.read() or '{}')
    except urllib.error.HTTPError as error:
        if error.code == 404 and body is None:
            return None
        raise RuntimeError(f'OpenBao operation failed: HTTP {error.code}') from None

try:
    jwt = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read().strip()
    token = request('auth/kubernetes/login', {'role': 'ocr-sandbox-bootstrap', 'jwt': jwt})['auth']['client_token']
    for key in ['ocr-sandbox-core-db-password', 'ocr-sandbox-ledger-db-password', 'ocr-sandbox-workload-key']:
        path = 'kv/data/ocr-sandbox/app/' + key
        if request(path) is None:
            request(path, {'options': {'cas': 0}, 'data': {'value': secrets.token_hex(32)}})
    print('Sandbox credentials present; existing values preserved.')
finally:
    if token:
        request('auth/token/revoke-self', {})
