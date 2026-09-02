#!/usr/bin/env python3
"""Scaffold the data plane for a SandboxDataSync claim.

Usage: scripts/scaffold-sandbox-sync.py k8s/operators/db-anonymise/claims/<product>.yaml

Reads the claim and generates everything it needs that is fully determined:
  - external-secrets/prod/<ns>/sandbox-sync.yaml (reader + sync ExternalSecrets)
  - registers the claim and the ExternalSecret in their kustomizations
  - schema/grants block appended to devai_evals_db.sql (column types are TODOs —
    mirror the source migration before merging)

Prints ready-to-paste snippets for the two files it will not edit in place
(source cluster managedRoles, istio-config appNamespaces) and the gcloud
commands for the Secret Manager entries. tests/test_sandbox_sync_wiring.py is
the merge gate: run pytest afterwards to see what is still missing.
"""

import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
EVALS_SQL = ROOT / "charts/apps/db-schema-bootstrap/schemas/global/global/devai_evals_db.sql"


def load_claim(path: Path) -> dict:
    docs = [d for d in yaml.safe_load_all(path.read_text()) if d]
    claims = [d for d in docs if d.get("kind") == "SandboxDataSync"]
    if len(claims) != 1:
        sys.exit(f"{path}: expected exactly one SandboxDataSync document")
    return claims[0]


def register(kustomization: Path, resource: str) -> bool:
    data = yaml.safe_load(kustomization.read_text()) if kustomization.exists() else {
        "apiVersion": "kustomize.config.k8s.io/v1beta1",
        "kind": "Kustomization",
        "resources": [],
    }
    if resource in data.get("resources", []):
        return False
    data.setdefault("resources", []).append(resource)
    kustomization.write_text(yaml.safe_dump(data, sort_keys=False))
    return True


def externalsecrets_yaml(ns: str, sync_secret: str) -> str:
    return f"""\
# DevAI sandbox evals sync credentials (k8s/operators/db-anonymise).
# URLs live whole in GCP Secret Manager; their embedded passwords must match
# the reader/writer role password secrets — GitOps cannot enforce that.
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {ns}-postgres-sandbox-reader
  namespace: {ns}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-secret-store
    kind: ClusterSecretStore
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
        key: prod-{ns}-sandbox-reader-password
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {sync_secret}
  namespace: {ns}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-secret-store
    kind: ClusterSecretStore
  target:
    name: {sync_secret}
    creationPolicy: Owner
  data:
    - secretKey: source-url
      remoteRef:
        key: prod-{ns}-sandbox-sync-source-url
    - secretKey: target-url
      remoteRef:
        key: prod-{ns}-sandbox-sync-target-url
    - secretKey: anonymization-salt
      remoteRef:
        key: prod-{ns}-sandbox-anonymization-salt
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
            tables = [t for t in claim["spec"]["tables"] if t["target"].startswith(f"{schema}.")]
            EVALS_SQL.write_text(EVALS_SQL.read_text() + sql_block(schema, tables))
            print(f"appended schema {schema} to devai_evals_db.sql — SET THE COLUMN TYPES")

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
3. Secret Manager (values never in Git; compose URLs in shell vars only):
     gcloud secrets create prod-{ns}-sandbox-reader-password --replication-policy=automatic
     gcloud secrets create prod-{ns}-sandbox-sync-source-url --replication-policy=automatic
     gcloud secrets create prod-{ns}-sandbox-sync-target-url --replication-policy=automatic
     gcloud secrets create prod-{ns}-sandbox-anonymization-salt --replication-policy=automatic
   target-url points at devai_evals_db on global-postgres-rw as devai_evals.
4. Fix the TODO column types in devai_evals_db.sql, then run:
     python3 -m pytest tests/test_sandbox_sync_wiring.py
""")
    subprocess.run(
        [sys.executable, "-m", "pytest", "tests/test_sandbox_sync_wiring.py", "-q"],
        cwd=ROOT,
        check=False,
    )


if __name__ == "__main__":
    main()
