# DevAI OpenBao migration

Tracking: [#1201](https://github.com/tesserix/tesserix-k8s/issues/1201).

## Final acceptance — 2026-09-27

All 40 approved GCP source secrets were deleted and verified absent. The five
retained platform dependencies still exist. DevAI migration acceptance and
post-deletion verification are recorded in issue #1201. The approved scope is
38 named application/legacy secrets and two private user credentials. All 43
live ESO bindings use namespace-scoped OpenBao readers, and all 18 complete
Kubernetes Secret hashes match their pre-cutover values. Mixed platform keys
remain unchanged. Each ExternalSecret completed a fresh OpenBao refresh.

The two user credentials retain their existing ownership under
`kv/devai/devai-api/<owner>/devai-*`. They were copied and read back through the
workload broker before a short, row-locked compare-and-swap reference update.
All other row fields and the separate preexisting OpenBao row were preserved.
There are no legacy user references. Repeating the migration verifies identical
values and references without overwriting credentials.

Delivery: #1202/#1203 staged the data and retired the temporary writer;
#1204 switched consumers and evals onboarding; #1205 added the guarded user
reference migration; tesserix-home#638 and #1206 restored the authenticated
workload broker. Parent synchronization exposed stale image seeds; #1207 aligned
all 16 affected application seeds with captured promoted versions. All 18
affected Deployments then became ready with the expected images.

Verification:

- All six namespace readers: byte equality, exact read-only capabilities and
  HTTP 403 for unrelated platform, product and user paths.
- Workload broker: DevAI identity accepted; foreign service account rejected
  with 404; missing credentials rejected with 401; console API still protected.
- API health/readiness and direct BFF health/auth configuration: HTTP 200.
  Application database connection and configured Vertex LLM generation passed.
- Anthropic and GitHub App authentication, registry catalog, MCP initialization
  and shared Kora gateway embeddings passed. Invalid Kora credentials returned 401.
- Six exact DevAI spans arrived in Langfuse through both OTel gateway replicas.
- Backup `20260927T115848Z-3d065023cc65` passed isolated restore in 22.683 seconds.
  The recovery catalog retained exactly three verified snapshots.
- Full local suite and CI passed: 550 tests and 48 subtests; four existing
  quarantines unchanged. The final image correction also passed ArgoCD validation.

Limitations: OpenAI and Gemini app entries are explicitly labelled bootstrap
placeholders; those optional providers are not configured. Public unauthenticated
requests receive HTTP 403 at the edge; interactive sign-in was not tested. The
existing internal MCP hub has authentication disabled, so successful internal
initialization does not establish invalid-token rejection. This migration did
not alter that policy.

Recovery captures (remote download/decrypt/equality verified):

- All 40 sources, metadata, IAM and enabled versions:
  `gs://tesseract-prod-backups-in/openbao/devai-migration/20260927T112417Z/gcp-sources.json.gz.kms`.
- Original user database rows:
  `gs://tesseract-prod-backups-in/openbao/devai-migration/20260927T112351Z/user-rows.json.gz.kms`.

Both archives use `openbao-backup-key`. Private journals and acceptance evidence
are in `/tmp/devai-openbao-evidence/` (0700), outside Git. User identifiers and
credential payloads must not enter public issues, logs or fixtures. Historical
migration archives follow the shared backup bucket's retention policy; they are
separate from the latest-three OpenBao recovery catalog.

The active account was `unidevidp@gmail.com`, project `tesseracthub-480811`, context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`. The repository remains
public. See issue #1201 for the final source-deletion and post-deletion record.

## Inventory

The reviewed inventory contained 40 GCP resources with enabled versions: 38 named application/legacy resources
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
field. Legacy and current credentials retain distinct paths. Legacy sources without live consumers were also archived and byte-verified.
Dormant fanzone provider references use a dedicated two-path reader, included
only in the dormant fanzone configuration. Evals onboarding writes DevAI
Langfuse credentials to OpenBao. No live workload or ConfigMap references the
retired GCP source names.

The current retained shared platform/bootstrap dependencies are
`prod-aregistry-jwt-secret`, `prod-ghcr-token`, `prod-ghcr-username`,
`prod-global-adk-runtime-upstream-token`, and `prod-qdrant-api-key`.
DevAI-owned provider credentials remain application candidates even when used
by Kora, kagent, or gateway infrastructure. DevAI Cloudflare credentials feed only the DevAI app configuration; platform
cert-manager, external-dns and Terraform retain their separate GCP sources.

Private source-version and user-reference metadata is in
`/tmp/devai-openbao-evidence/` (directory mode 0700), outside Git. It holds encrypted recovery captures and private metadata, never plaintext
credential payload files. User identifiers and
runtime mappings must not enter public issues, logs, fixtures, or this repo.

## Historical phase one — access and staging tools

- Six `devai-production-reader` ServiceAccounts and
  `openbao-devai-production` SecretStores.
- Roles bind both the specific namespace and ServiceAccount. Policies grant
  only `read` on that namespace's observed app-secret paths; no user paths,
  wildcard, metadata listing, writes, or deletion.
- Staging used `devai-migrate-reviewed`, with `create,read` on the 38 explicit
  destinations, bound only to `openbao/devai-migration-writer` for 15 minutes.
  The migration token was revoked. This cleanup revision removes its role,
  account and policy; persistent namespace readers remain read-only.
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

## Historical migration sequence and acceptance gates

1. Completed for the 38 named sources: encrypted archive, remote recovery
   round-trip, create-only copies, byte equality and six namespace scope checks.
   The two private user credentials remain outside this staging plan.
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

## Historical baseline and local validation

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


## Staging correction and cleanup validation

The first staging attempt stopped on an absent destination (HTTP 404), before
any write, and revoked its token. The shared client was missing the approved
`kv/data/devai/app/` prefix in its create-on-missing handling. A regression test
reproduced this, then passed after the narrow prefix addition. The retry created
all 38 destinations; it did not overwrite any existing value.

Cleanup/fix validation: 540 repository tests and 48 subtests passed, with the same
four existing CI quarantines. Helm lint, Ruff and diff checks passed. DevAI API
health/readiness remained HTTP 200 after staging. Runtime consumer cutover has
not happened, so these checks do not establish that the application reads its
new app secrets from OpenBao yet.
