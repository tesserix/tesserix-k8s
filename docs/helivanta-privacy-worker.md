# Helivanta privacy deadline worker rollout

The privacy module owns case-clock metadata. The worker uses only its dedicated
PostgreSQL role and Temporal task queue; it cannot read case descriptions or
clinical records. No tenant deadline policy, officer or notice is seeded.

## Release order

1. Reconcile the OpenBao bootstrap and namespace grants, Istio control-plane and
   Temporal client grants, and Helivanta namespace exclusions. Kubernetes network
   policies are additive: broad namespace and HBONE policies must exclude both
   the worker and credential initializer.
2. Reconcile the Postgres chart with `privacyWorker.seed.enabled`,
   `privacyWorker.credentials.enabled` and `privacyWorker.login` true. The bounded
   initializer creates a random credential using OpenBao CAS zero and a
   create-only policy. Existing versions are preserved; deleted versions fail
   closed. ESO exposes this one credential to the restricted worker identity.
3. Verify the initializer completed, ExternalSecret is Ready and the managed role
   exists with no inheritance, memberships, superuser or RLS bypass. Never print
   credential values. The application migration requires the role to exist.
4. Release a tested API image containing `/app/privacy-worker` and migration
   `0002_privacy` through the existing Helivanta Kargo pipeline. Preserve the
   pre-release migration ledger and schema without exporting patient data.
5. Enable `privacyDeadlines.enabled` only with the compatible image present.
   Verify both worker replicas, database TLS, Temporal connectivity and exact
   source image. Run synthetic case/replay/isolation checks before approving any
   tenant policy. Check actual worker observations; pod readiness alone is not
   end-to-end evidence.

The API and other enabled workflow features must agree on Temporal namespace and
address; rendering fails on a mismatch. Defaults leave workflow activation off.

## Recovery and verification

Do not delete the database role, clocks, audit records or credential on rollback.
After a policy has accepted cases, retain compatible consumers and workers until
those workflows finish. Disabling the API feature switch stops policy approval
and consumption but does not invalidate existing policies; it is not a safe
rollback after activation. Case deadlines do not authorize disclosure or erasure.

Local regression: `uv run --with pytest --with pyyaml pytest -q
 tests/test_helivanta*.py` verifies chart rendering and isolation assertions.
Backend PostgreSQL/JetStream/Temporal acceptance separately verifies worker
restart and duplicate terminal delivery. Neither substitutes for live checks.

This adds two small worker replicas and a one-shot credential job, using the
existing database and Temporal cluster. No new managed service is provisioned.
Current production readiness and activation must be recorded after reconciliation;
this document does not assert rollout completion.
