# Roamie gateway and JEV credential handoff

Roamie generation, speech and JEV use the dedicated `roamie-ai` native gateway in
`agentgateway-system`. The API delegates a verified Zitadel customer token and
holds no TypeSafe credential. Gateway ExternalSecret `roamie-typesafe-credentials`
reads exact KV v2 path `roamie/app/roamie-typesafe-api-key`, property `value`.
Only the gateway namespace's production Roamie reader gains that path. The
application namespace reader has no TypeSafe access.

Source: `kora/app/kora-typesafe-api-key`. Select and record a numeric source version
before copying. `scripts/copy_roamie_jev_secret.py` reads that pinned version,
uses create-only CAS=0, refuses unequal existing values and verifies byte equality
without printing either value. Repeated identical copies are idempotent.
Development uses a separate `roamie-development` path and reader. This copy script
does not reuse a production credential for development.

Use a short-lived operator token with only these exact capabilities:

```hcl
path "kv/data/kora/app/kora-typesafe-api-key" { capabilities = ["read"] }
path "kv/data/roamie/app/roamie-typesafe-api-key" { capabilities = ["create", "read"] }
```

With a verified loopback OpenBao port-forward and `BAO_TOKEN` provided through a
secure operator session, run:

```sh
python3 scripts/copy_roamie_jev_secret.py --source-version APPROVED_VERSION
```

Do not paste credentials in chat or Git. Revoke the temporary operator token
when finished. No source deletion, overwrite or rotation is involved. Until
separate vendor keys exist, rotation must update and verify both product copies.
Provider retention/privacy admission must cover Roamie before real documents
are sent to TypeSafe.

Read-only discovery used account `unidevidp@gmail.com`, project
`tesseracthub-480811`, context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, namespaces `roamie`,
`agentgateway-system`, `tesserix` and `openbao`. Existing Roamie API, manager,
MCP and agent replicas were ready. No scoped OpenBao operator token was available,
so the credential copy and reader-policy update have not run.

Activation requires explicit approval for the named production changes:

1. Copy the pinned key and reconcile the gateway-only OpenBao reader.
2. Apply the `roamie_agentgateway_wi` Terraform member in stack `12-vertex`.
3. Sync `roamie-api-gateway` and verify ExternalSecret readiness and Gateway
   acceptance. Its production AppProject adds `agentgateway-system` as a destination.
4. Import the twelve Registry resources through the existing platform seed, now
   45 resources. Route-sync remains their only production writer.
5. Publish/pin the new API image with `AI_GATEWAY_ORIGIN`, then validate a real
   signed test customer through mobile, OCR/JEV, generation and the console ledger.
6. Admit production usage only after the unresolved security and release gates
   in Roamie's `docs/production-readiness.md` are resolved.

Registry/Git revision and previous API image are the rollback. Keep the copied
key and OCR source data. No database migration is needed for this Roamie change;
the console ledger's existing schema must already be deployed. Disabling the
seed does not remove imported resources. Never imperatively overwrite Registry
resources that the sync controller will reconcile.

The chart contains strict Zitadel project/mobile-client validation, API-only
workload admission, bounded requests/timeouts, gateway-only credentials and
metadata-based console attribution. The API has no provider key or direct
production model fallback. Helm lint, 16 integration/copy/reader/ownership tests,
Terraform validation/tests and installed-CRD server dry-run passed. A real
AgentGateway v1.4.1 synthetic probe verified JWT rejection, credential replacement,
header removal and export; the captured event was replayed through real Postgres
once. Production mesh authorization, live console arrival and secret copying
remain unverified.


Native speech uses fixed `/v1/speech` → global Vertex
`gemini-3.8-flash-tts:generateContent`, GCP backend authentication and the same
strict delegated-customer/API-workload boundary. Request/response buffers are
8 KiB/3 MiB with a 45-second deadline. The Registry owns the additional backend,
route and traffic policy. Native usage tokens are exported without text/audio
payloads to the existing console ledger; no speech price is invented. An actual
v1.4.1 synthetic native-speech probe verified identity/header stripping and token
metadata, and its captured event is included in the isolated ledger replay check.
