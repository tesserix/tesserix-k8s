# DevAI OpenBao migration

Tracking: [#1201](https://github.com/tesserix/tesserix-k8s/issues/1201).

## Status — 2026-09-27

Inventory and phase-one access changes are prepared locally. No DevAI source
has been copied or deleted, no consumer switched, and no database reference
changed. Deployment, copy verification, functional acceptance and cleanup remain
open. This document is not a completion record.

Read-only discovery used account `unidevidp@gmail.com`, project
`tesseracthub-480811`, context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`.
The repository remains public.

## Inventory

40 GCP resources have enabled versions: 38 named application/legacy resources
in [the inventory](devai-openbao-secret-inventory.csv) and two private user-scoped
credentials. The named sources have 43 live ExternalSecret bindings producing
18 Kubernetes Secret targets in six namespaces:

| Consumer namespace | Bindings | Distinct source secrets |
| --- | ---: | ---: |
| `agentgateway-system` | 9 | 6 |
| `agentregistry-system` | 1 | 1 |
| `devai` | 26 | 24 |
| `global` | 1 | 1 |
| `kagent-system` | 2 | 2 |
| `observability` | 4 | 2 |

Each named destination is `kv/devai/app/devai-<secret-name>`, with one `value`
field. Legacy and current credentials retain distinct paths. Sources without
live ESO consumers remain candidates; absence of a binding is not proof of
safe deletion. Dormant GitOps consumers (including fanzone provider refs) and
credential producers must be checked before deleting sources.

The current retained shared platform/bootstrap dependencies are
`prod-aregistry-jwt-secret`, `prod-ghcr-token`, `prod-ghcr-username`,
`prod-global-adk-runtime-upstream-token`, and `prod-qdrant-api-key`.
DevAI-owned provider credentials remain application candidates even when used
by Kora, kagent, or gateway infrastructure. Cloudflare credentials require an
ownership/use check before source retirement.

Private source-version and user-reference metadata is in
`/tmp/devai-openbao-evidence/` (directory mode 0700), outside Git. It contains no
copied credential payloads and is not a recovery archive. User identifiers and
runtime mappings must not enter public issues, logs, fixtures, or this repo.

## Phase one — reviewable access and staging tools

- Six `devai-production-reader` ServiceAccounts and
  `openbao-devai-production` SecretStores.
- Roles bind both the specific namespace and ServiceAccount. Policies grant
  only `read` on that namespace's observed app-secret paths; no user paths,
  wildcard, metadata listing, writes, or deletion.
- Temporary `devai-migrate-reviewed` policy grants `create,read` on the 38
  explicit app destinations. Its Kubernetes login role binds only
  `openbao/devai-migration-writer`, with 15 minutes TTL. A token must have this
  policy only (plus optional default). Remove the role, account and policy
  after staging and revoke issued tokens.
- `scripts/migrate_devai_secrets.py` rejects platform and user sources,
  duplicate sources, nonnumeric versions and mismatched destinations. It reuses
  the existing staging implementation: verifies the active account and source
  version, creates with KV CAS=0, compares readback bytes, records metadata only,
  refuses differing existing values, and revokes the writer token on exit.

Only the OpenBao chart and external-secrets access resources change in this
phase. Existing ESO consumer mappings stay on GCP until copies are verified.
There are no new services or storage requirements; access objects add negligible
cost. A failed copy leaves GCP and current consumers intact. A rerun accepts
identical existing values and stops on differences; partial progress is journaled.

Threat model: application and per-user credentials are assets; a compromised
workload or another tenant must not gain access through the migration. The
boundary is GCP identity, namespace-bound Kubernetes authentication, exact
OpenBao ACLs and existing per-user runtime ownership. App-reader policies do not
include the user credential subtree. Secret payloads must never enter Git/logs.

Local dry-run commands (no secret payload reads/writes):

```sh
python3 scripts/migrate_devai_secrets.py --plan /tmp/devai-openbao-evidence/app-plan.json
python3 scripts/migrate_devai_secrets.py --plan /tmp/devai-openbao-evidence/app-plan.json --policy
```

Execution requires an encrypted recovery archive first, current pinned-version
review, verified temporary policy/token, and approval of the named live phase.
Do not issue a root token or widen the writer on a permission error.

## Subsequent phases and acceptance gates

1. Archive the approved source payloads with the existing KMS-backed backup
   mechanism, record the object/generation and restore evidence privately;
   copy the 38 named candidates and verify exact bytes and scope.
2. Prepare coordinated GitOps cutovers for DevAI API/auth BFF/registry, shared
   gateways (including Kora), kagent, global databases, Langfuse and OTel.
   Preserve mixed platform references, Secret target names/keys, transformations
   and Kargo-managed Helm parameter arrays. Update DevAI credential producers
   (evals onboarding) and metadata consumers before retiring GCP sources.
3. Separately migrate the two legacy user credentials through the existing
   workload secret broker. The two legacy refs are in one enabled user LLM
   connector row; another enabled row already has an OpenBao ref. Resolve owner
   mapping using the current adapter and preserve the existing OpenBao row.
   Do not flatten user secrets into the app prefix. Copy/readback first, then a
   short row-locked compare-and-swap transaction on the exact original
   `secret_refs` mapping. No network calls while database locks are held.
   Capture the original row securely. This database change needs named approval.
4. Test fresh ESO reconciliation, byte equality, actual runtime OpenBao reads,
   database connections, API/BFF authentication, user connector reads, provider
   calls, registry/MCP and Langfuse/OTel. Run Kora regression checks because it
   shares a DevAI provider credential. Ready pods alone do not satisfy this gate.
5. Remove temporary access, run a new backup and isolated restore, confirm latest
   three retained backups, and record the encrypted source recovery capture.
6. Request deletion approval for the exact successfully migrated GCP resources;
   archive metadata needed to recreate them before deleting. Rerun functional
   checks after deletion. Close #1201 only when all acceptance checks pass.

Rollback before source deletion is a reviewed GitOps consumer-reference revert;
user reference rollback requires the original private mapping and guarded database
update. After deletion, recovery depends on the verified encrypted source archive.
Do not delete first and rely on the existence of a backup alone.

## Baseline and local validation

Read-only live checks: DevAI API 3/3 and worker 2/2 ready; all listed DevAI
Deployments meet desired replicas. API `/healthz` and `/readyz` returned HTTP 200.
This establishes a starting baseline, not post-migration functional acceptance.

The migration tests failed first for the absent tool; access tests failed for
missing roles, writer policy and stores. After implementation, 77 targeted
migration/access tests passed. `helm lint charts/thirdparty/openbao` passed and
`kubectl kustomize external-secrets/prod` rendered successfully. Ruff format and
lint passed on the new Python files. The full repository suite passed: 539 tests and 48 subtests, with the four
pre-existing CI quarantines unchanged. The first attempt lacked Helm dependencies;
a second exposed a local dependency symlink conflicting with a fixture. Packaging
the local dependencies resolved both setup issues; no test assertions changed.
`mypy --follow-imports=skip scripts/migrate_devai_secrets.py`, `py_compile`, the
38-source CLI dry run, and `git diff --check` also passed. No strict typing or
application functional cutover acceptance is claimed by these infrastructure checks.
