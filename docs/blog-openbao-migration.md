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
