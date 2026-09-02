# DevAI Sandbox Data Sync — anonymized product data for evals

Product data is anonymized and copied daily into the DevAI-owned
`devai_evals_db` on global-postgres (one schema per product) by the
`devai-sandbox-operator` (repo `tesserix/tesserix-operators`). Nothing product-
scoped lives on global-postgres as its own database — only the DevAI evals
dataset.

## How it runs

A namespaced `SandboxDataSync` claim in `k8s/operators/db-anonymise/claims/`
declares the tables, columns, and per-column transforms (`preserve`, `hash`,
`email`, `name`, `redact` — HMAC-SHA-256 with a per-product salt; emails become
`user-<digest>@sandbox.invalid`). The operator materialises a policy ConfigMap
and a CronJob; the sync worker takes a repeatable-read snapshot through a
SELECT-only reader role, transforms rows, then `TRUNCATE … RESTART IDENTITY
CASCADE` + `COPY` into the target. The worker does **no DDL** — target tables
are provisioned by `db-schema-bootstrap`, and `devai_evals_db` is in
`reapplyExistingSchemas` so grants for new schemas converge.

## Onboarding a product

1. Write the claim (copy `claims/kora.yaml`).
2. Run `scripts/scaffold-sandbox-sync.py claims/<product>.yaml` — it generates
   the ExternalSecrets, kustomization entries, and the schema/grants block in
   `devai_evals_db.sql` (set the TODO column types from the source migration),
   and prints the snippets and `gcloud secrets create` commands for the rest.
3. Add the reader role to the source cluster's `managedRoles` and the
   namespace to istio-config `appNamespaces` (both need chart version bumps).
4. Create the four Secret Manager entries. Full DATABASE_URLs are stored whole
   (house pattern); never compose `postgresql://user:pass@` strings in Git.

`tests/test_sandbox_sync_wiring.py` gates the PR: every claim must have its
kustomization registration, secret keys, reader role, target DDL, grants, and
mesh path, so a partially wired claim cannot merge.

## Verifying a run

```bash
kubectl create job <product>-sync-manual --from=cronjob/sandbox-sync-<claim> -n <ns>
kubectl logs job/<product>-sync-manual -n <ns>   # "sandbox data sync completed"
kubectl exec global-postgres-1 -n global -c postgres -- \
  psql -d devai_evals_db -tAc "SELECT count(*) FROM <schema>.<table>"
```
