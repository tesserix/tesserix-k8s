import importlib.util
import json
import pathlib
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
import yaml
from test_homechef_openbao_access import render, resource

ROOT = pathlib.Path(__file__).parents[1]
PRODUCT = ROOT / "charts/apps/document-intelligence/products/homechef-prod.yaml"
RELEASE = "document-intelligence-homechef-prod"
SEED = RELEASE + "-secret-seed"
SEED_ROLE = "seed-homechef-document-intelligence-production"
STORE = "openbao-homechef-production"
DB_KEY = "homechef/app/homechef-document-intelligence-db-password"
OCR_KEY = "homechef/app/homechef-api-ocr-key"
READERS = {
    "document-intelligence": [OCR_KEY, DB_KEY],
    "global": [DB_KEY],
    "homechef": [OCR_KEY],
}


def helm(release, chart, *args):
    output = subprocess.check_output(
        ["helm", "template", release, str(ROOT / chart), *args], text=True
    )
    return [d for d in yaml.safe_load_all(output) if d]


def kustomize(path):
    output = subprocess.check_output(["kubectl", "kustomize", str(ROOT / path)], text=True)
    return [d for d in yaml.safe_load_all(output) if d]


def release():
    return helm(
        RELEASE,
        "charts/apps/document-intelligence",
        "--namespace",
        "document-intelligence",
        "-f",
        str(PRODUCT),
    )


def openbao_config():
    return resource(render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap")["data"]


def test_release_reads_homechef_paths_and_admits_only_the_api():
    docs = release()
    db = resource(docs, "ExternalSecret", RELEASE + "-db")
    assert db["spec"]["secretStoreRef"] == {"name": STORE, "kind": "SecretStore"}
    assert db["spec"]["data"][0]["remoteRef"] == {"key": DB_KEY, "property": "value"}
    assert "document_intelligence_homechef_prod:" in db["spec"]["target"]["template"]["data"]["DATABASE_URL"]
    identity = resource(docs, "ExternalSecret", RELEASE + "-api-identity")
    assert identity["spec"]["target"]["template"]["data"]["OCR_WORKLOAD_IDENTITY_KEYS"] == (
        "homechef-v1=homechef:{{ .client_0 | trim }}"
    )
    assert [e["remoteRef"]["key"] for e in identity["spec"]["data"]] == [OCR_KEY]
    for api in ("upload-api", "job-api"):
        policy = resource(docs, "AuthorizationPolicy", f"{RELEASE}-{api}-clients")
        assert [s["source"]["principals"] for r in policy["spec"]["rules"] for s in r["from"]] == [
            ["cluster.local/ns/homechef/sa/homechef-api"]
        ]


def test_credentials_are_seeded_create_only_before_the_release_syncs():
    docs = release()
    job = resource(docs, "Job", SEED)
    assert job["metadata"]["annotations"]["argocd.argoproj.io/hook"] == "PreSync"
    pod = job["spec"]["template"]
    assert pod["spec"]["serviceAccountName"] == SEED
    assert pod["spec"]["automountServiceAccountToken"] is False
    env = {e["name"]: e["value"] for e in pod["spec"]["containers"][0]["env"]}
    assert env == {"OPENBAO_ROLE": SEED_ROLE, "SEED_KEYS": f"{DB_KEY},{OCR_KEY}"}
    for kind in ("ServiceAccount", "ConfigMap", "NetworkPolicy"):
        hook = resource(docs, kind, SEED)["metadata"]["annotations"]
        assert int(hook["argocd.argoproj.io/sync-wave"]) < int(
            job["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"]
        )
    assert "app.kubernetes.io/instance" not in pod["metadata"]["labels"]

    config = openbao_config()
    role = json.loads(config[f"role-{SEED_ROLE}.json"])
    assert role["bound_service_account_names"] == [SEED]
    assert role["bound_service_account_namespaces"] == ["document-intelligence"]
    assert role["token_ttl"] == "5m"
    policy = config[f"policy-{SEED_ROLE}.hcl"]
    assert dict(re.findall(r'path "([^"]+)"\s*{\s*capabilities = \[([^]]+)\]', policy)) == {
        "kv/data/" + DB_KEY: '"create", "read"',
        "kv/data/" + OCR_KEY: '"create", "read"',
        "auth/token/revoke-self": '"update"',
    }

    access = render("charts/apps/openbao-namespace")
    sources = resource(access, "NetworkPolicy", "allow-clients-to-openbao")["spec"]["ingress"][0]["from"]
    assert {
        "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "document-intelligence"}},
        "podSelector": {"matchLabels": pod["metadata"]["labels"]},
    } in sources
    principals = [
        p
        for rule in resource(access, "AuthorizationPolicy", "allow-known-sources")["spec"]["rules"]
        for f in rule["from"]
        for p in f["source"].get("principals", [])
    ]
    assert f"cluster.local/ns/document-intelligence/sa/{SEED}" in principals


def test_readers_are_exact_read_only_and_namespace_bound():
    config = openbao_config()
    docs = kustomize("external-secrets/prod")
    for namespace, keys in READERS.items():
        name = f"read-homechef-{namespace}-production"
        role = json.loads(config[f"role-{name}.json"])
        assert role["bound_service_account_names"] == ["homechef-production-reader"]
        assert role["bound_service_account_namespaces"] == [namespace]
        assert role["token_policies"] == [name]
        policy = config[f"policy-{name}.hcl"]
        assert set(re.findall(r'path "([^"]+)"', policy)) == {"kv/data/" + k for k in keys}
        assert set(re.findall(r"capabilities = \[([^]]+)\]", policy)) == {'"read"'}
        store = next(
            d
            for d in docs
            if d["kind"] == "SecretStore"
            and d["metadata"] == {"name": STORE, "namespace": namespace}
        )
        auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
        assert auth == {"mountPath": "kubernetes", "role": name, "serviceAccountRef": {"name": "homechef-production-reader"}}


def test_database_role_schema_and_task_queue_are_declared():
    values = yaml.safe_load((ROOT / "charts/apps/global-postgres/values.yaml").read_text())
    assert {
        "name": "document_intelligence_homechef_prod",
        "passwordSecret": "global-postgres-document-intelligence-homechef-prod",
        "comment": "homechef prod document intelligence runtime writer",
    } in values["managedRoles"]
    assert {"name": "document_intelligence_homechef_prod_db", "owner": "global"} in values["databases"]
    secret = next(
        d
        for d in kustomize("external-secrets/prod")
        if d["kind"] == "ExternalSecret"
        and d["metadata"] == {"name": "global-postgres-document-intelligence-homechef-prod", "namespace": "global"}
    )
    assert secret["spec"]["target"]["template"]["data"]["username"] == "document_intelligence_homechef_prod"
    assert secret["spec"]["data"][0]["sourceRef"]["storeRef"] == {"name": STORE, "kind": "SecretStore"}
    assert secret["spec"]["data"][0]["remoteRef"] == {"key": DB_KEY, "property": "value"}

    schema = ROOT / "charts/apps/db-schema-bootstrap/schemas/global/global/document_intelligence_homechef_prod_db.sql"
    assert "TO document_intelligence_homechef_prod;" in schema.read_text()
    bootstrap = (ROOT / "argocd/prod/apps/global/global-db-schema-bootstrap.yaml").read_text()
    assert "- document_intelligence_homechef_prod_db" in bootstrap
    temporal = yaml.safe_load((ROOT / "charts/apps/temporal-platform-resources/values.yaml").read_text())
    assert RELEASE in {n["name"] for n in temporal["temporalNamespaces"]}


def test_api_signs_ocr_calls_against_the_homechef_release():
    services = {d["metadata"]["name"] for d in release() if d["kind"] == "Service"}
    docs = helm(
        "homechef-api",
        "charts/apps/homechef-api",
        "--namespace",
        "homechef",
        "-f",
        str(ROOT / "charts/apps/homechef-api/values-prod.yaml"),
    )
    for name in ("homechef-api", "homechef-api-temporal-worker"):
        deployment = resource(docs, "Deployment", name)
        env = {e["name"]: e for e in deployment["spec"]["template"]["spec"]["containers"][0]["env"]}
        for var, api in (("OCR_UPLOAD_URL", "upload-api"), ("OCR_JOB_URL", "job-api")):
            assert env[var]["value"] == f"http://{RELEASE}-{api}.document-intelligence.svc.cluster.local:8080"
            assert f"{RELEASE}-{api}" in services
        assert env["OCR_KEY_ID"]["value"] == "homechef-v1"
        assert re.fullmatch(r"ten_[A-Za-z0-9_]{1,64}", env["OCR_TENANT"]["value"])
        assert env["OCR_KEY_SECRET"]["valueFrom"]["secretKeyRef"] == {
            "name": "homechef-ocr-client",
            "key": "OCR_KEY_SECRET",
            "optional": True,
        }
    client = resource(docs, "ExternalSecret", "homechef-ocr-client")
    assert client["spec"]["secretStoreRef"] == {"name": STORE, "kind": "SecretStore"}
    assert client["spec"]["data"] == [
        {"secretKey": "OCR_KEY_SECRET", "remoteRef": {"key": OCR_KEY, "property": "value"}}
    ]
    assert not any(d["kind"] == "ExternalSecret" and d["metadata"]["name"] == "homechef-ocr-client"
                   for d in helm("homechef-api", "charts/apps/homechef-api"))


def test_api_egress_reaches_only_the_homechef_ocr_apis():
    policy = resource(kustomize("manifests/homechef-istio"), "NetworkPolicy", "allow-homechef-api-to-ocr-egress")
    assert policy["spec"]["podSelector"] == {"matchLabels": {"app.kubernetes.io/name": "homechef-api"}}
    assert policy["spec"]["policyTypes"] == ["Egress"]
    assert policy["spec"]["egress"] == [
        {
            "to": [
                {
                    "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "document-intelligence"}},
                    "podSelector": {
                        "matchLabels": {"app.kubernetes.io/instance": RELEASE},
                        "matchExpressions": [
                            {"key": "app.kubernetes.io/component", "operator": "In", "values": ["upload-api", "job-api"]}
                        ],
                    },
                }
            ],
            "ports": [{"protocol": "TCP", "port": 8080}, {"protocol": "TCP", "port": 15008}],
        }
    ]


class FakeOpenBao(BaseHTTPRequestHandler):
    store: dict = {}
    revoked: list = []

    def log_message(self, *args):
        pass

    def reply(self, code, body=None):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(json.dumps(body or {}).encode())

    def do_GET(self):
        key = self.path.removeprefix("/v1/kv/data/")
        if key in self.store:
            self.reply(200, {"data": {"data": {"value": self.store[key]}}})
        else:
            self.reply(404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/v1/auth/kubernetes/login":
            ok = body == {"role": SEED_ROLE, "jwt": "projected-token"}
            return self.reply(200 if ok else 403, {"auth": {"client_token": "t"}})
        if self.headers["X-Vault-Token"] != "t":
            return self.reply(403)
        if self.path == "/v1/auth/token/revoke-self":
            self.revoked.append(True)
            return self.reply(204)
        key = self.path.removeprefix("/v1/kv/data/")
        if body["options"] != {"cas": 0} or key in self.store or key.startswith("deleted/"):
            return self.reply(400)
        self.store[key] = body["data"]["value"]
        self.reply(200)


@pytest.fixture
def seeder(tmp_path, monkeypatch):
    server = HTTPServer(("127.0.0.1", 0), FakeOpenBao)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    FakeOpenBao.store, FakeOpenBao.revoked = {"homechef/app/existing": "keep"}, []
    token = tmp_path / "token"
    token.write_text("projected-token\n")
    spec = importlib.util.spec_from_file_location(
        "secret_seed", ROOT / "charts/apps/document-intelligence/files/secret-seed.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "BASE", f"http://127.0.0.1:{server.server_port}/v1/")
    monkeypatch.setattr(module, "TOKEN", str(token))
    monkeypatch.setenv("OPENBAO_ROLE", SEED_ROLE)
    yield module
    server.shutdown()


def test_seed_creates_missing_credentials_and_preserves_existing_ones(seeder, monkeypatch):
    monkeypatch.setenv("SEED_KEYS", f"homechef/app/existing,{OCR_KEY}")
    seeder.main()
    assert FakeOpenBao.store["homechef/app/existing"] == "keep"
    assert re.fullmatch(r"[0-9a-f]{64}", FakeOpenBao.store[OCR_KEY])
    assert FakeOpenBao.revoked == [True]


def test_seed_refuses_to_recreate_a_deleted_credential(seeder, monkeypatch):
    monkeypatch.setenv("SEED_KEYS", "deleted/key")
    with pytest.raises(Exception):
        seeder.main()
    assert "deleted/key" not in FakeOpenBao.store
    assert FakeOpenBao.revoked == [True]
