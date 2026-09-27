#!/usr/bin/env python3
"""Scaffold the data plane for a SandboxDataSync claim.

Usage: scripts/scaffold-sandbox-sync.py k8s/operators/db-anonymise/claims/<product>.yaml

Reads the claim and generates everything it needs that is fully determined:
  - external-secrets/prod/<ns>/sandbox-sync.yaml (reader + sync ExternalSecrets)
  - registers the claim and the ExternalSecret in their kustomizations
  - schema/grants block appended to devai_evals_db.sql (column types are TODOs —
    mirror the source migration before merging)

Prints ready-to-paste snippets for the two files it will not edit in place
(source cluster managedRoles, istio-config appNamespaces) and the scoped OpenBao
reader policy/role and application paths. tests/test_sandbox_sync_wiring.py is
the merge gate: run pytest afterwards to see what is still missing.
"""

import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
EVALS_SQL = (
    ROOT / "charts/apps/db-schema-bootstrap/schemas/global/global/devai_evals_db.sql"
)


def load_claim(path: Path) -> dict:
    docs = [d for d in yaml.safe_load_all(path.read_text()) if d]
    claims = [d for d in docs if d.get("kind") == "SandboxDataSync"]
    if len(claims) != 1:
        sys.exit(f"{path}: expected exactly one SandboxDataSync document")
    return claims[0]


def register(kustomization: Path, resource: str) -> bool:
    data = (
        yaml.safe_load(kustomization.read_text())
        if kustomization.exists()
        else {
            "apiVersion": "kustomize.config.k8s.io/v1beta1",
            "kind": "Kustomization",
            "resources": [],
        }
    )
    if resource in data.get("resources", []):
        return False
    data.setdefault("resources", []).append(resource)
    kustomization.write_text(yaml.safe_dump(data, sort_keys=False))
    return True


def validate_name(value: str) -> None:
    if len(value) > 63 or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", value):
        raise ValueError("Require a DNS label for namespace and secret names")


def product_name(ns: str) -> str:
    validate_name(ns)
    return "fe3dr" if ns in {"homechef", "homechef-development"} else ns


def externalsecrets_yaml(ns: str, sync_secret: str) -> str:
    product = product_name(ns)
    validate_name(sync_secret)
    return f"""\
# DevAI sandbox evals sync credentials (k8s/operators/db-anonymise).
# URLs live whole in OpenBao; their embedded passwords must match
# the reader/writer role password secrets — GitOps cannot enforce that.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {ns}-sandbox-secret-reader
  namespace: {ns}
automountServiceAccountToken: false
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: openbao-{ns}-sandbox-sync
  namespace: {ns}
spec:
  provider:
    vault:
      server: http://openbao.openbao.svc.cluster.local:8200
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: read-{ns}-sandbox-sync
          serviceAccountRef:
            name: {ns}-sandbox-secret-reader
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {ns}-postgres-sandbox-reader
  namespace: {ns}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-{ns}-sandbox-sync
    kind: SecretStore
  target:
    name: {ns}-postgres-sandbox-reader
    creationPolicy: Owner
    # CNPG managed.roles expects basic-auth shape (username/password).
    template:
      type: kubernetes.io/basic-auth
      data:
        username: "{ns}_sandbox_reader"
        password: "{{{{ .password }}}}"
  data:
    - secretKey: password
      remoteRef:
        key: {ns}/sandbox-sync/{product}-sandbox-reader-password
        property: value
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {sync_secret}
  namespace: {ns}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-{ns}-sandbox-sync
    kind: SecretStore
  target:
    name: {sync_secret}
    creationPolicy: Owner
  data:
    - secretKey: source-url
      remoteRef:
        key: {ns}/sandbox-sync/{product}-sandbox-sync-source-url
        property: value
    - secretKey: target-url
      remoteRef:
        key: {ns}/sandbox-sync/{product}-sandbox-sync-target-url
        property: value
    - secretKey: anonymization-salt
      remoteRef:
        key: {ns}/sandbox-sync/{product}-sandbox-anonymization-salt
        property: value
"""


def sql_block(schema: str, tables: list) -> str:
    lines = [f"\nCREATE SCHEMA IF NOT EXISTS {schema};\n"]
    for table in tables:
        target = table["target"]
        columns = ",\n".join(
            f"    {column['name']} TEXT  -- TODO: mirror the source migration's type"
            for column in table["columns"]
        )
        lines.append(f"CREATE TABLE IF NOT EXISTS {target} (\n{columns}\n);\n")
    lines.append(
        "DO $$\nBEGIN\n"
        f"  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'devai_evals') THEN\n"
        f"    EXECUTE 'GRANT USAGE ON SCHEMA {schema} TO devai_evals';\n"
        f"    EXECUTE 'GRANT SELECT, INSERT, TRUNCATE ON ALL TABLES IN SCHEMA {schema} TO devai_evals';\n"
        "  END IF;\nEND\n$$;\n"
    )
    return "".join(lines)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    claim_path = Path(sys.argv[1]).resolve()
    claim = load_claim(claim_path)
    ns = claim["metadata"]["namespace"]
    sync_secret = claim["spec"]["source"]["secretRef"]["name"]
    product = product_name(ns)
    validate_name(sync_secret)
    schemas = {t["target"].split(".", 1)[0] for t in claim["spec"]["tables"]}

    if register(claim_path.parent / "kustomization.yaml", claim_path.name):
        print(f"registered {claim_path.name} in claims kustomization")

    es_dir = ROOT / "external-secrets/prod" / ns
    es_dir.mkdir(parents=True, exist_ok=True)
    es_file = es_dir / "sandbox-sync.yaml"
    if not es_file.exists():
        es_file.write_text(externalsecrets_yaml(ns, sync_secret))
        register(es_dir / "kustomization.yaml", "sandbox-sync.yaml")
        print(f"wrote {es_file.relative_to(ROOT)}")

    sql = EVALS_SQL.read_text()
    for schema in sorted(schemas):
        if f"CREATE SCHEMA IF NOT EXISTS {schema}" not in sql:
            tables = [
                t
                for t in claim["spec"]["tables"]
                if t["target"].startswith(f"{schema}.")
            ]
            EVALS_SQL.write_text(EVALS_SQL.read_text() + sql_block(schema, tables))
            print(
                f"appended schema {schema} to devai_evals_db.sql — SET THE COLUMN TYPES"
            )

    print(f"""
Manual steps the tests will hold you to:
1. Source cluster reader role — add to charts/apps/{ns}-postgres/values.yaml
   (or global-postgres if the product DB lives there) and bump the chart version:
     managedRoles:
       - name: {ns}_sandbox_reader
         passwordSecret: {ns}-postgres-sandbox-reader
         inRoles:
           - pg_read_all_data
         comment: SELECT-only reader for the DevAI sandbox evals sync
2. Mesh path — ensure `{ns}: {ns}` is under appNamespaces in
   charts/thirdparty/istio-config/values.yaml (bump chart version).
3. OpenBao (payloads never in Git or CLI arguments):
   Add the exact reader policy and Kubernetes role printed below to the OpenBao
   bootstrap values through GitOps. Grant a temporary writer only these four paths,
   write field `value` through stdin/API bodies, verify reader access, then revoke it.
   Production and development namespaces must have separate paths and identities.
   target-url points at devai_evals_db on global-postgres-rw as devai_evals.
4. Fix the TODO column types in devai_evals_db.sql, then run:
     python3 -m pytest tests/test_sandbox_sync_wiring.py
""")
    suffixes = (
        "sandbox-reader-password",
        "sandbox-sync-source-url",
        "sandbox-sync-target-url",
        "sandbox-anonymization-salt",
    )
    policy = "\n".join(
        f'path "kv/data/{ns}/sandbox-sync/{product}-{suffix}" {{ capabilities = ["read"] }}'
        for suffix in suffixes
    )
    print(
        yaml.safe_dump(
            {
                "bootstrap": {
                    "policies": [{"name": f"read-{ns}-sandbox-sync", "hcl": policy}],
                    "kubernetesRoles": [
                        {
                            "name": f"read-{ns}-sandbox-sync",
                            "serviceAccounts": [f"{ns}-sandbox-secret-reader"],
                            "namespaces": [ns],
                            "policies": [f"read-{ns}-sandbox-sync"],
                            "ttl": "15m",
                        }
                    ],
                }
            },
            sort_keys=False,
        )
    )
    subprocess.run(
        [sys.executable, "-m", "pytest", "tests/test_sandbox_sync_wiring.py", "-q"],
        cwd=ROOT,
        check=False,
    )


if __name__ == "__main__":
    main()
