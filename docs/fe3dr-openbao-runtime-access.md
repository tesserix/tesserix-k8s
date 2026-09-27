# fe3dr runtime and development access

Tracks #1159. `runtime-fe3dr-payment` is bound only to the existing
`homechef/homechef-api` Kubernetes service account used by API and worker.
Its ten-minute tokens can read/create/update the 17 explicitly listed gateway
fields and fe3dr vendor/driver payment paths. Only payment-owner metadata can be
deleted. PII, JWT/session, other products and development values are outside its
write scope. PII startup uses the separate existing read-only application role.

Development UPI sources use `homechef-development/homechef-api/fe3dr-...`.
The production application roles cannot read this prefix. A separate
`homechef/fe3dr-development-reader` identity has read-only access for recovery
verification. There is no active fe3dr development workload/namespace in this
cluster; this change does not start one or allow the production API to consume
its credentials. A restored development deployment needs its own namespace
binding and development backend configuration before use.

No backend switch is enabled by these grants. Cutover order: deploy tested
pause-capable application code on GCP, pause credential mutations, drain old
writers, reconcile source versions and destination values, test actual runtime
ACLs, switch API and worker together, verify read paths, then resume writes.
PII moves after existing ciphertext/blind-index compatibility and restore checks.
The user approved the scoped write pause on 2026-09-27. The pause keeps reads and
checkout available and also defers vendor account erasure.

A failed onboarding secret write returns a retryable 503; retry the complete
request. Secret fields and database updates are not an atomic transaction.
Rollback after any OpenBao write requires reverse reconciliation before
selecting GCP. Source deletion still requires verified encrypted recovery and
successful consumer acceptance, regardless of whether these grants exist.
