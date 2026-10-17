# Questionnaire database and routing

Application source and form/research guide live in tesserix-home:
`docs/guides/vending-questionnaires.md` and `docs/adr/0007-vending-questionnaires.md`.

Production targets: namespace tesserix, existing tesserix-postgres CNPG cluster,
database questionnaires, public host questionnaire.tesserix.app. No new cluster
or external datastore is provisioned. Preserve all existing databases and roles.

The tesserix-postgres chart conditionally adds a retained CNPG Database, two
managed login roles with eight-connection limits, separate namespace-bound ESO
readers, and a one-time CAS=0 secret seed Job. OpenBao stores both passwords at
questionnaires/prod/app/questionnaires-{writer,reader}-password. The seed can
create/read these exact paths and revoke itself; it cannot overwrite or delete
existing values. CNPG consumes the resulting basic-auth Secrets. Application
credentials are never read from a new GCP Secret Manager source.

The schema source is
`charts/apps/db-schema-bootstrap/schemas/questionnaires/tesserix/001_questionnaires.sql`.
A dedicated bootstrap Application combines the SQL chapters into questionnaires
and replays only that idempotent database schema every five minutes. Database
creation is declarative through CNPG; do not rely on postInitSQL on a live cluster.

Rollout order: reconcile OpenBao policies and namespace admission, then the
CNPG chart/seed and ESO Secrets, then wait for the new managed roles and Database
Ready condition, then schema bootstrap success, then public/console configuration
and application images. Argo may retry during dependency convergence. Verify all
components, not just Application Synced. Existing application replicas can continue
with their existing images during provisioning. Revert questionnaire routing and
application image/config through GitOps for rollback; retain database and secrets.
There is no destructive production down migration.

The public role may only execute questionnaires_api.submit and questionnaires_api.reserve_lookup; it may not read,
update or delete responses. The console role can select the two response schemas
but cannot execute submission or mutate data. The function compares exact JSON
for replay, bounds inputs, atomically stores preferences, and uses shared durable
admission counters. These are separate survey datasets, not a customer-login tenant
model. An external tenant dashboard would need a new scoped authorisation design.

Company and console reuse their existing deployments. Only their new questionnaire
pool uses the new roles. TLS verifies the CNPG CA. The public VirtualService has an
explicit path allowlist and a 404 fallback, so console/admin/internal endpoints are
not published on the questionnaire hostname. Existing wildcard TLS/ingress and
external-DNS conventions provide hosting; verify actual DNS and HTTPS after sync.

## Verification

`python -m unittest tests.test_questionnaires` checks rendered isolation and grants.
For behavioural database checks, use an EMPTY local scratch database named
questionnaires with ordinary PGHOST/PGPORT/PGUSER/PGPASSWORD variables and run:

```
python scripts/test_questionnaires.py
python scripts/test_questionnaires_locations.py
```

This creates two scratch roles, verifies denial before schema installation,
applies the production schema twice, then exercises submission, replay, changed
intent, product rollback, cross-role denials and admission limits. It must never
be pointed at production. There is no cleanup SQL in production manifests.

Check the live Database and managed-role status, bootstrap Job success, API
submissions/receipt replay, both public pages, anonymous console denial, authenticated
console reporting, and existing CNPG backup/continuous archiving conditions. Use
clearly named synthetic responses and retain their references in private test
evidence. Do not print credentials or genuine respondent data. Existing cluster
backup applies to this database; a fresh full-cluster disaster restore is outside
this feature's verification and must not be implied by a schema test.

## Existing location integration

The company app reuses `mark8ly-platform-api.mark8ly.svc.cluster.local:8086` for
`GET /api/v1/locations/countries` and `mark8ly-storefront.mark8ly.svc.cluster.local:4203`
for `GET /api/locations/autocomplete`, using the fixed public marketing Host
`mark8ly.com` required by the storefront's host router. These are existing public
reference endpoints; no internal credential or respondent session is forwarded.
The existing `allow-tesserix-egress` policy already admits the Mark8ly namespace,
and no NetworkPolicy selects the destination frontend/API pods. No broader network
rule or product configuration is needed for this integration.

The questionnaire gateway and VirtualService admit only the exact anonymous
`POST /api/questionnaires/location` endpoint. It accepts a bounded JSON body, applies
origin and input checks, and reserves shared admission before fetching at most eight
validated suggestions. Limits are 300/minute global and 30/minute per hashed client.
Writer cannot read counters or responses; reader cannot execute either public function.
No new provider key, OpenBao path or external service is created. Optional location
search failure falls back to manual fields. The public catalog's current 16 currencies
are supported, including whole-unit JPY; existing responses and receipts retain meaning.

Credential readers refresh every minute so an initial not-found result recovers
promptly after the write-once seed succeeds. OpenBao namespace admission can reconcile
later than the seed Job; Kubernetes retries seed attempts for up to ten minutes.
Schema bootstrap retries on its five-minute schedule and never changes other databases.
A failed early schema run before managed roles exist is safe: the transaction rolls back.
Verify a later successful run, both ESO Ready conditions and reconciled CNPG roles before
publishing the forms. A refresh annotation can request immediate ESO reconciliation
without changing or rotating the stored credential.

ESO-generated database credentials carry `cnpg.io/reload: "true"`, matching the
existing CNPG secret-watch convention. This is required for the database controller
to observe initial creation and later approved credential updates. The existing Reloader
watches the exact writer secret for company and reader secret for console, so consumers
refresh their environment and connection pools after a change. No rotation is performed
by bootstrap; its CAS=0 writes preserve existing values. An approved future rotation
must verify the CNPG role update and both application rollouts before retiring recovery
material. Do not assume overlapping database passwords or a zero-disruption rotation.
