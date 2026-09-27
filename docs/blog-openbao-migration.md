# Blog secret migration — #1187

Five blog-specific GCP secrets are in scope. Shared Resend already comes from
OpenBao (`homechef/homechef-api/fe3dr-resend-api-key`) and is not duplicated.
Platform identity providers, image registry credentials and recovery keys remain
in GCP. No credential rotation, database replacement or schema migration occurs.

| GCP source | Version | OpenBao KV v2 path |
|---|---|---|
| `prod-blog-keycloak-client-secret` | 2 | `blog/app/blog-keycloak-client-secret` |
| `prod-blog-mongodb-root-password` | 1 | `blog/app/blog-mongodb-root-password` |
| `prod-blog-mongodb-uri` | 1 | `blog/app/blog-mongodb-uri` |
| `prod-blog-oidc-client-secret` | 2 | `blog/app/blog-oidc-client-secret` |
| `prod-blog-session-secret` | 1 | `blog/app/blog-session-secret` |

Four namespace-bound reader identities receive exact-path read permission: the
app reads URI/session/OIDC, the database and backup readers read only the root
password, and a separate legacy reader retains the dormant Keycloak consumer.
The temporary writer has create/read on these five paths, no overwrite/delete,
a 15-minute token, and is removed after staging. The migration helper reuses
CAS=0 copies, compares existing bytes, fails on differing destinations and revokes
its token even after failure. Journals contain metadata only.

Threat boundary: authentication, session and database credentials must not reach
other products, application logs or the public repository. ESO authenticates with
namespace-bound Kubernetes identities; the app receives unchanged Kubernetes
Secret keys. API callers never receive secret payloads from migration tooling.

Execution: `scripts/migrate_blog_secrets.py --plan PLAN.json` validates pinned
versions; `--policy` renders the exact-path grant. Use `--execute --account ACCOUNT
--journal JOURNAL` only after GitOps installs the temporary role. Stage before
consumer cutover. Verify byte equality and wrong-product/write denials, then
reconcile consumers and test the blog and authenticated database access. Archive
source metadata/IAM and versions securely, and verify the post-copy Raft backup
before deleting GCP originals. Force fresh ESO reconciliation after deletion.

Before deletion, rollback is reverting consumer sources. After deletion, restore
archived GCP values and IAM first or repair the OpenBao source; a Git revert alone
cannot recreate deleted originals. Existing Kubernetes values remain available
if a secret-provider refresh fails. No new cloud resources are required; removing
GCP versions reduces Secret Manager storage/access usage.

Baseline: blog homepage and health return 200. MongoDB is healthy but Argo attempts
an immutable storage-class change. The legacy identity Argo app references a
removed chart. MongoDB backup Jobs are failing their existing deadline. Record
migration acceptance and disposition of these findings before closing #1187.

## Staging evidence (2026-09-27)

All five destination values at KV version 1 were compared byte-for-byte with the
pinned sources. The migration token was revoked. The writer role/policy and KSA
are removed from desired state in the consumer rollout; explicitly remove the
orphaned OpenBao role/policy after that rollout, since bootstrap upserts grants
but does not prune omitted grants. No permanent application write grant remains.

Source metadata, IAM and all enabled versions are archived at:
`gs://tesseract-prod-backups-in/openbao/blog-migration/20260927T073552Z/gcp-sources.json.gz.kms`.
The archive is gzip JSON encrypted with `openbao-backup-key`, additionally stored
with GCS CMEK and the bucket's existing retention. Its decryption round trip was
verified in memory. Restore by KMS decrypting then gunzipping in a controlled
process; never print payloads. Disabled/destroyed historical versions have metadata
only. Preserve the KMS key and archive until the recovery window closes.

The runtime has no direct GCP Secret Manager client. MongoDB URI and OIDC are
active app credentials. Session and Keycloak secrets are retained for compatibility
(the current app does not reference SESSION_SECRET in its source). Shared Resend
stays in OpenBao under its existing coordinated path. Old seed-script comment
examples using `gcloud secrets versions access prod-blog-mongodb-uri` must instead
obtain MONGODB_URI from the synchronized `tesserix/tesserix-blog-secrets` Secret or
the scoped OpenBao reader; do not reintroduce a GCP runtime dependency.

Existing backup/legacy identity infrastructure findings are tracked separately in
#1189. They predate migration; published-post API baseline is 21 posts, HTTP 200.

The earlier `20260927T072511Z` archive is invalid (empty exported payloads) and
has an `INVALID.txt` marker. Use only the replacement above: it was downloaded
from GCS, decrypted in memory and compared against all five pinned GCP values.
Use the migration helper’s base64 payload API format; GCP SM `--out-file=-`
writes a literal file rather than stdout. The unintended local file was removed
without displaying or committing its contents.
