# Company and console OpenBao migration

Tracks [#1209](https://github.com/tesserix/tesserix-k8s/issues/1209).
Status: completed through #1241 and #1242. Seven pinned values migrated, all ten
bindings freshly verified after source deletion, and seven GCP originals deleted.
Both scoped readers and all 13 company/console/auth-bff functional checks passed.
Four deployments remain ready with unchanged images and Argo parameters.

The company application has seven remaining GCP references, with ten confirmed
ESO bindings across the Tesserix and Mark8ly namespaces. Use production paths
under `tesserix/app/` and identifiers beginning `tesserix-`.

| GCP source | OpenBao identifier | Confirmed consumers |
| --- | --- | --- |
| `prod-internal-service-key` | `tesserix-internal-service-key` | company |
| `prod-tesserix-internal-api-token` | `tesserix-internal-api-token` | company, Mark8ly admin |
| `prod-github-token` | `tesserix-github-token` | company |
| `prod-marketplace-content-admin-key` | `tesserix-marketplace-content-admin-key` | company onboarding |
| `prod-argocd-auth-token` | `tesserix-argocd-auth-token` | company |
| `prod-tesserix-session-encrypt-key` | `tesserix-session-encrypt-key` | company, console, tesserix-auth-bff |
| `prod-tesserix-sendgrid-webhook-secret` | `tesserix-sendgrid-webhook-secret` | company event verification |

The session key has THREE live consumers. Older comments in the company/console
charts incorrectly describe only two. The third ExternalSecret is
`tesserix/tesserix-session`, owned by `external-secrets-resources` and declared in
`external-secrets/prod/tesserix/externalsecret.yaml`. Preserve identical bytes
across all three; no session-key rotation is part of this migration.

The Tesserix reader can read exactly these seven paths. The Mark8ly reader can
read only the internal API token. Neither can list, create, overwrite or delete.
The staging writer was namespace-bound with a fifteen-minute TTL and exact
create/read permissions. Its issued token has been revoked; this cutover removes
its desired role, policy and service account. The
migration script validates pinned versions, uses CAS=0 and refuses differences.
Retire the writer and its issued tokens once staging and readback are complete.

Before deletion, finish shared-consumer and cold-start review beyond the ESO
inventory; absence of another ESO binding does not establish exclusive ownership.
Archive all recoverable enabled versions, metadata and IAM under KMS encryption.
Test provider access and authenticated application flows without sending email,
changing content, creating deployments or modifying customer records. Verify
fresh ESO synchronization, whole-Secret equality, all three session readers,
Mark8ly internal API access, unchanged images, isolated restore and independent
recovery before retiring any source.

The product repository is `tesserix/tesserix-home`. Its secrets API already
defaults new writes to OpenBao but retains an explicitly selectable GCP backend
for remaining sources. Do not remove that backend while other products still
need it. The old GCP metadata health helper has no production function callers
in the current source scan; verify imports and tests before removing the unused
SDK dependency. Keep the portal's OpenBao metadata-only health checks read-blind.

## Staging evidence and legacy credential

All seven pinned values and ten existing ESO bindings matched. Recoverable GCP
metadata, IAM and enabled versions were encrypted and verified at
`gs://tesseract-prod-backups-in/openbao/company-migration/20260928T085926Z/gcp-sources.json.gz.kms`.

Company health, anonymous/invalid session denial, internal API token authentication
and a short-lived synthetic encrypted session passed through an authorized local
port-forward. The GitHub token authenticated successfully. Public endpoint checks
returned 403 from the external access layer and are not application evidence.

The legacy Argo token fails authenticated Argo access. The deployed company and
console source (`main-419b036`) has no production use of `ARGOCD_AUTH_TOKEN`;
the value is preserved unchanged, and is not counted as a passing credential.
No rotation is included. Remaining console, database and shared platform sources
are separate migration cohorts; this seven-source cohort does not complete them.

## Completion evidence

The temporary writer service account, role and policy are absent and issued tokens
were revoked. Backup `20260928T092744Z-ce6799cb6c66` restored in 20.289 seconds,
with three verified backups retained and pruning confirmed. All four whole-Secret
hashes matched before and after deletion. No cluster ExternalSecret references
remain to these seven GCP sources. The seven-day source-access audit returned no
records and therefore is not additional evidence of exclusive ownership.

Cleanup total after this cohort: 285; fresh remaining GCP inventory: 390.
The next cohort is tracked in `docs/console-openbao-migration.md`.
