# Cross-DB super-admin role (`<product>_platform_admin`)

## What this is

`tesserix-home` is the platform-operator super-admin for every product
running in this cluster (mark8ly, future fanzone, homechef, …). It owns
only its own data locally in `tesserix-postgres` (apps registry + leads).
Everything else is read **live cross-namespace** from each product's
own database — no ETL.

To do that, each product DB gets a single elevated role with CRUD scope
that `tesserix-home` connects as. The role is intentionally **not** the
product's own application role (which has full owner privileges and is
dangerous to share) and intentionally **not** read-only (the super-admin
needs destructive ops: tenant cleanup, billing override, mark-paid).

## The role's grants (mark8ly example)

```sql
CREATE ROLE mark8ly_platform_admin LOGIN PASSWORD '<...>'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

-- For each database (mark8ly_platform_api, mark8ly_marketplace_api):
GRANT CONNECT ON DATABASE <db> TO mark8ly_platform_admin;
GRANT USAGE ON SCHEMA public TO mark8ly_platform_admin;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA public TO mark8ly_platform_admin;
GRANT USAGE, UPDATE
  ON ALL SEQUENCES IN SCHEMA public TO mark8ly_platform_admin;

-- Critical: future tables auto-inherit. Set both default-privilege
-- sources — the database superuser AND the table-owner application
-- role — because tables created by either path need to be reachable.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO mark8ly_platform_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, UPDATE ON SEQUENCES TO mark8ly_platform_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE <product_app_role> IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO mark8ly_platform_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE <product_app_role> IN SCHEMA public
  GRANT USAGE, UPDATE ON SEQUENCES TO mark8ly_platform_admin;
```

**Explicitly NOT granted:** `SUPERUSER`, `CREATEDB`, `CREATEROLE`,
`REPLICATION`, `BYPASSRLS`, any DDL (`CREATE/DROP/ALTER TABLE`).
Schema migrations remain 100% owned by the product's own services.

## Provisioning runbook (one-time, per product)

Adapt for each product (replace `<product>` and database names).

```bash
PROJECT=tesseracthub-480811
PRODUCT=mark8ly
SECRET_KEY=prod-${PRODUCT}-platform-admin-password

# 1. Generate password and store in GCP Secret Manager. Use 32 ASCII chars
#    (UTF-8-safe AES-256 length) — kubelet rejects non-UTF-8 env values.
PWD=$(openssl rand -base64 24 | tr -d '\n')
echo -n "$PWD" | gcloud secrets create $SECRET_KEY \
  --project=$PROJECT --data-file=- --replication-policy=automatic

# 2. Provision the role + grants on the product's CNPG cluster.
PG_POD=$(kubectl -n $PRODUCT get pods -l cnpg.io/cluster=${PRODUCT}-postgres,role=primary -o name | head -1)
kubectl -n $PRODUCT exec $PG_POD -c postgres -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PRODUCT}_platform_admin') THEN
      CREATE ROLE ${PRODUCT}_platform_admin LOGIN PASSWORD '$PWD'
        NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    ELSE
      ALTER ROLE ${PRODUCT}_platform_admin WITH PASSWORD '$PWD';
    END IF;
  END
  \$\$;
"

# 3. Apply grants per database (repeat for each).
for DB in <list of databases>; do
  kubectl -n $PRODUCT exec $PG_POD -c postgres -- psql -U postgres -d $DB -v ON_ERROR_STOP=1 -c "
    GRANT CONNECT ON DATABASE $DB TO ${PRODUCT}_platform_admin;
    GRANT USAGE ON SCHEMA public TO ${PRODUCT}_platform_admin;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${PRODUCT}_platform_admin;
    GRANT USAGE, UPDATE ON ALL SEQUENCES IN SCHEMA public TO ${PRODUCT}_platform_admin;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
      GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${PRODUCT}_platform_admin;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
      GRANT USAGE, UPDATE ON SEQUENCES TO ${PRODUCT}_platform_admin;
  "
done
unset PWD

# 4. Add an ExternalSecret in tesserix namespace pointing at the new key.
#    (See external-secrets/prod/tesserix/externalsecret.yaml.)

# 5. Add the product's namespace + DB cluster name to the apps registry
#    table (tesserix-postgres.tesserix_admin.apps).

# 6. Open a NetworkPolicy egress rule from tesserix → <product> namespace
#    on port 5432 if not already covered by crossProductNamespaceAccess
#    in charts/thirdparty/istio-config/values.yaml.
```

## Conventions for cross-DB writes

Every mutating call from `tesserix-home` (or `tesserix-admin-api`)
against a product DB must:

1. **Run inside a transaction.** Single `BEGIN ... COMMIT` per logical
   operation. Never autocommit a multi-statement destructive op.
2. **Lock the parent row.** For tenant-level destructive ops:
   `SELECT 1 FROM tenants WHERE id = $1 FOR UPDATE` at the start.
3. **Insert an audit_events row in the same transaction.** The product's
   own audit module won't see writes that bypass its handlers, so the
   super-admin's writes are responsible for keeping the audit log honest.
   Use `actor='${product}_platform_admin'`, `source='tesserix-home'`,
   include enough context (`reason`, `affected_ids`).
4. **Two-step confirm in the UI for destructive ops.** Hard-delete is
   irreversible; require an explicit "type the tenant name to confirm"
   step plus a server-side deletion-preview that lists what will go.

## Revoking access

```sql
REVOKE ALL PRIVILEGES ON DATABASE <db> FROM <product>_platform_admin;
DROP OWNED BY <product>_platform_admin CASCADE;
DROP ROLE <product>_platform_admin;
```

Then delete the GCP Secret Manager key and remove the ExternalSecret.
The cluster network path can stay open or be tightened by removing the
namespace from `crossProductNamespaceAccess` in `istio-config` values.

## Adding a new product (fanzone, homechef, …)

1. Run the provisioning runbook above with `PRODUCT=<slug>`.
2. Add an ExternalSecret entry in
   `external-secrets/prod/tesserix/externalsecret.yaml` named
   `<product>-platform-admin`.
3. Add the product's namespace to `crossProductNamespaceAccess` in
   `charts/thirdparty/istio-config/values.yaml`:
   ```yaml
   crossProductNamespaceAccess:
     tesserix:
       - mark8ly
       - <new-product>
   ```
4. Insert a row into `tesserix-postgres.tesserix_admin.apps` with the
   product slug, DB host, role-credentials secret name, and admin URL.
5. The dashboard becomes multi-product without code restructure.

## Why not a read-only role?

The original proposal was `<product>_reader` (SELECT only). Rejected
because the super-admin needs destructive ops (tenant archive, billing
override, mark-paid, hard-delete with cascade preview). Read-only would
force a runbook for every routine ops action — defeats the point of an
admin UI. The CRUD scope here is the principle-of-least-privilege upper
bound: enough to do the ops job, not enough to alter schema or escalate.
