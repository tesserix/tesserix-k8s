import importlib.util
from pathlib import Path
from types import SimpleNamespace

from test_homechef_openbao_access import render, resource
from test_openbao_recovery_record import PAYLOAD


def test_bootstrap_uses_independent_record_and_retained_staging():
    docs = render("charts/thirdparty/openbao")
    config = resource(docs, "ConfigMap", "openbao-bootstrap")["data"]
    script = config["bootstrap.sh"]
    assert "gcloud secrets" not in script
    assert "recovery_record.py" in config
    assert "recovery_record.py store" in script
    assert "recovery_record.py load" in script
    assert "--data-binary @/tmp/request" in script
    assert "-H @/tmp/headers" in script
    assert "refusing to initialise" in script
    pvc = resource(docs, "PersistentVolumeClaim", "openbao-bootstrap-staging")
    assert (
        pvc["metadata"]["annotations"]["argocd.argoproj.io/sync-options"]
        == "Prune=false"
    )
    assert pvc["spec"]["storageClassName"] == "standard-rwo-retain"
    job = next(
        d
        for d in docs
        if d["kind"] == "Job" and d["metadata"]["name"].startswith("openbao-bootstrap-")
    )
    pod = job["spec"]["template"]["spec"]
    assert any(
        v.get("persistentVolumeClaim", {}).get("claimName")
        == "openbao-bootstrap-staging"
        for v in pod["volumes"]
    )
    container = pod["containers"][0]
    env = {e["name"]: e.get("value") for e in container["env"]}
    assert (
        env["RECOVERY_OBJECT_URI"]
        == "gs://tesseracthub-480811-openbao-bootstrap-prod/bootstrap/init.json.kms"
    )
    assert env["RECOVERY_KMS_KEY"].endswith("/cryptoKeys/openbao-bootstrap-key")
    assert env["ALLOW_INITIALIZATION"] == "false"
    assert container["command"] == [
        "python3",
        "/config/recovery_record.py",
        "run",
        "/config/bootstrap.sh",
    ]


def checker():
    path = Path(__file__).parents[1] / "scripts/check_break_glass.py"
    spec = importlib.util.spec_from_file_location("break_glass", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_break_glass_checks_independent_record_and_revoked_initial_root(
    monkeypatch, capsys
):
    module = checker()
    calls = []

    def api(path, token=None, method="GET", body=None):
        calls.append((path, token))
        if path == "sys/health":
            return 200, {"initialized": True, "sealed": False, "version": "synthetic"}
        if path == "auth/kubernetes/login":
            return 200, {
                "auth": {
                    "client_token": "synthetic-bootstrap",
                    "policies": ["bootstrap", "default"],
                    "lease_duration": 600,
                }
            }
        if path == "sys/mounts":
            return 200, {}
        if path == "auth/token/revoke-self":
            return 204, {}
        return 403, {}

    monkeypatch.setattr(module, "api", api)
    monkeypatch.setattr(module, "recovery_record", lambda: PAYLOAD)
    monkeypatch.setattr(
        module.subprocess,
        "run",
        lambda *a, **k: SimpleNamespace(stdout="synthetic-jwt"),
    )
    assert module.main() == 0
    assert ("auth/token/lookup-self", "synthetic-root") in calls
    output = capsys.readouterr()
    assert "synthetic-root" not in output.out + output.err
    assert "synthetic-jwt" not in output.out + output.err


def bootstrap_fixture(tmp_path, *, initialized, configured, record_exists, fail_puts=0):
    import base64
    import json
    import os
    import sys

    from test_openbao_recovery_record import KEY, MODULE, URI

    config = tmp_path / "config"
    staging = tmp_path / "staging"
    scratch = tmp_path / "scratch"
    binaries = tmp_path / "bin"
    for folder in [config, staging, scratch, binaries]:
        folder.mkdir()
    docs = render("charts/thirdparty/openbao")
    data = resource(docs, "ConfigMap", "openbao-bootstrap")["data"]
    jwt = tmp_path / "jwt"
    jwt.write_text("synthetic-jwt")
    script = (
        data["bootstrap.sh"]
        .replace("/tmp/", str(scratch) + "/")
        .replace("/config/", str(config) + "/")
    )
    script = script.replace(
        "SA_TOKEN_PATH=/var/run/secrets/kubernetes.io/serviceaccount/token",
        f'SA_TOKEN_PATH="{jwt}"',
    )
    (config / "bootstrap.sh").write_text(script)
    (config / "recovery_record.py").write_text(MODULE.read_text())
    (config / "policy-bootstrap.hcl").write_text(
        'path "sys/*" { capabilities = ["read"] }'
    )
    (config / "role-bootstrap.json").write_text("{}")
    cloud = tmp_path / "cloud.json"
    server = tmp_path / "server.json"
    cloud.write_text(
        json.dumps(
            {
                "cipher": base64.b64encode(b"encrypted:" + PAYLOAD).decode()
                if record_exists
                else None,
                "fail_puts": fail_puts,
            }
        )
    )
    server.write_text(
        json.dumps(
            {
                "initialized": initialized,
                "configured": configured,
                "root_active": not configured,
                "init_calls": 0,
                "argv": [],
                "payload": base64.b64encode(PAYLOAD).decode(),
            }
        )
    )
    gcloud = r"""
import base64,json,os,sys
from pathlib import Path
p=Path(os.environ['CLOUD_STATE']);state=json.loads(p.read_text());args=sys.argv[1:]
if args[:2]==['storage','cat']:
 if state['cipher'] is None:sys.stderr.write('404 not found');sys.exit(1)
 sys.stdout.buffer.write(base64.b64decode(state['cipher']))
elif args[:2]==['kms','encrypt']:sys.stdout.buffer.write(b'encrypted:'+sys.stdin.buffer.read())
elif args[:2]==['kms','decrypt']:
 data=sys.stdin.buffer.read();assert data.startswith(b'encrypted:');sys.stdout.buffer.write(data[10:])
elif args[:2]==['storage','cp']:
 assert '--if-generation-match=0' in args
 if state['fail_puts']:
  state['fail_puts']-=1;p.write_text(json.dumps(state));sys.exit(1)
 if state['cipher'] is not None:sys.stderr.write('412 conflict');sys.exit(1)
 state['cipher']=base64.b64encode(Path(args[2]).read_bytes()).decode();p.write_text(json.dumps(state))
else:raise RuntimeError('Unexpected cloud operation')
"""
    curl = r"""
import base64,json,os,sys
from pathlib import Path
from urllib.parse import urlsplit
args=sys.argv[1:];p=Path(os.environ['CURL_STATE']);state=json.loads(p.read_text());state['argv'].append(args)
assert not any('synthetic-root' in a or 'synthetic-jwt' in a for a in args)
url=next(a for a in args if a.startswith('http'));path=urlsplit(url).path
out=Path(args[args.index('-o')+1]);code=200;response={};token=''
for i,a in enumerate(args):
 if a=='-H' and args[i+1].startswith('@'):
  header=Path(args[i+1][1:]).read_text().strip();token=header.split(': ',1)[1]
if path=='/v1/sys/seal-status':response={'initialized':state['initialized'],'sealed':False}
elif path=='/v1/sys/init':
 assert not state['initialized'];state['init_calls']+=1;state['initialized']=True;state['root_active']=True
 response=json.loads(base64.b64decode(state['payload']))
elif path=='/v1/sys/health':pass
elif path=='/v1/auth/kubernetes/login':
 if state['configured']:response={'auth':{'client_token':'synthetic-bootstrap'}}
 else:code=403;response={'errors':['not configured']}
else:
 if token=='synthetic-root':assert state['root_active']
 else:assert token=='synthetic-bootstrap' and state['configured']
 if path=='/v1/auth/kubernetes/role/bootstrap':state['configured']=True
 if path=='/v1/auth/token/revoke-self':
  code=204
  if token=='synthetic-root':state['root_active']=False
  else:state['bootstrap_revoked']=True
p.write_text(json.dumps(state));out.write_text(json.dumps(response))
if '-w' in args:sys.stdout.write(str(code))
sys.exit(1 if '-sf' in args and code>=400 else 0)
"""
    for name, source in [("gcloud", gcloud), ("curl", curl)]:
        executable = binaries / name
        executable.write_text(f"#!{sys.executable}\n" + source)
        executable.chmod(0o755)
    env = {
        **os.environ,
        "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
        "CLOUD_STATE": str(cloud),
        "CURL_STATE": str(server),
        "RECOVERY_OBJECT_URI": URI,
        "RECOVERY_KMS_KEY": KEY,
        "RECOVERY_STAGING_DIR": str(staging),
        "ALLOW_INITIALIZATION": "true",
    }
    command = [
        sys.executable,
        str(config / "recovery_record.py"),
        "run",
        str(config / "bootstrap.sh"),
    ]
    return command, env, staging, cloud, server


def test_failed_initial_persistence_resumes_without_reinitialising(tmp_path):
    import base64
    import json
    import subprocess

    command, env, staging, cloud, server = bootstrap_fixture(
        tmp_path, initialized=False, configured=False, record_exists=False, fail_puts=1
    )
    failed = subprocess.run(
        command, env=env, capture_output=True, text=True, check=False
    )
    assert failed.returncode != 0
    assert (staging / "init.json").read_bytes() == PAYLOAD
    assert (staging / "init.json").stat().st_mode & 0o777 == 0o600
    retried = subprocess.run(
        command, env=env, capture_output=True, text=True, check=False
    )
    assert retried.returncode == 0, retried.stdout + retried.stderr
    state = json.loads(server.read_text())
    assert state["init_calls"] == 1 and state["configured"] and not state["root_active"]
    assert not (staging / "init.json").exists()
    assert base64.b64decode(json.loads(cloud.read_text())["cipher"])[10:] == PAYLOAD
    assert (
        "synthetic-root"
        not in failed.stdout + failed.stderr + retried.stdout + retried.stderr
    )


def test_existing_recovery_record_blocks_new_initialisation(tmp_path):
    import json
    import subprocess

    command, env, _, _, server = bootstrap_fixture(
        tmp_path, initialized=False, configured=False, record_exists=True
    )
    result = subprocess.run(
        command, env=env, capture_output=True, text=True, check=False
    )
    assert result.returncode != 0
    assert json.loads(server.read_text())["init_calls"] == 0
    assert "refusing to initialise" in result.stdout


def test_steady_bootstrap_revokes_temporary_token(tmp_path):
    import json
    import subprocess

    command, env, _, _, server = bootstrap_fixture(
        tmp_path, initialized=True, configured=True, record_exists=True
    )
    env["ALLOW_INITIALIZATION"] = "false"
    result = subprocess.run(
        command, env=env, capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stdout + result.stderr
    state = json.loads(server.read_text())
    assert state["init_calls"] == 0 and state["bootstrap_revoked"]


def test_initialisation_requires_explicit_opt_in(tmp_path):
    import json
    import subprocess

    command, env, _, cloud, server = bootstrap_fixture(
        tmp_path, initialized=False, configured=False, record_exists=False
    )
    env["ALLOW_INITIALIZATION"] = "false"
    result = subprocess.run(
        command, env=env, capture_output=True, text=True, check=False
    )
    assert result.returncode != 0
    assert json.loads(server.read_text())["init_calls"] == 0
    assert json.loads(cloud.read_text())["cipher"] is None


def test_concurrent_bootstrap_refuses_locked_staging(tmp_path):
    import fcntl
    import json
    import subprocess

    command, env, staging, _, server = bootstrap_fixture(
        tmp_path, initialized=False, configured=False, record_exists=False
    )
    with (staging / ".bootstrap.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run(
            command, env=env, capture_output=True, text=True, check=False
        )
    assert result.returncode != 0
    assert json.loads(server.read_text())["init_calls"] == 0
    assert "details withheld" in result.stdout
