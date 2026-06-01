# devai-api/files

## devai_db.sql — LOCAL bootstrap mirror

`devai_db.sql` is a **synced copy** of the canonical DevAI schema:

```
../../db-schema-bootstrap/schemas/devai/devai_db/devai_db.sql
```

It exists here only because Helm `.Files.Get` can read files **inside the chart
dir** but not a sibling chart's. The `schemaBootstrap` init container
(`templates/configmap-schema.yaml` + `templates/deployment.yaml`, gated by
`schemaBootstrap.enabled`, **on only in `values-local.yaml`**) mounts it and
applies it to `devai_db` on a fresh kind cluster.

**Single source of truth stays in `db-schema-bootstrap`.** When the canonical
schema changes, re-copy it:

```bash
cp ../db-schema-bootstrap/schemas/devai/devai_db/devai_db.sql files/devai_db.sql
```

In **prod** the init container is OFF — schemas are applied by the
`db-schema-bootstrap` CronJob. This mirror is never used in prod.
