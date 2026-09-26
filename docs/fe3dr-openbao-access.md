# fe3dr persistent OpenBao access — phase 1

Status: approved for GitOps rollout; deployment and live verification pending. No application secret values or GCP references change in this phase.

## Access contract

| Consumer | Kubernetes identity | OpenBao role | KV v2 data path | Access |
|---|---|---|---|---|
| API and Temporal worker | `homechef/homechef-api` | `app-homechef_homechef-api` | `kv/data/homechef/homechef-api/*` | read |
| BFF via ESO | `homechef/homechef-auth-bff` | `app-homechef_homechef-auth-bff` | `kv/data/homechef/homechef-auth-bff/*` | read |

Metadata access is read/list on each corresponding `kv/metadata/…` prefix. The role TTL defaults to one hour. No writes, deletes, policy administration, platform secrets, or other app paths are granted. The two API workloads share their service account and cannot be distinguished by OpenBao permissions; separating their authority later requires separate identities.

The legacy `read-homechef` role remains available for compatibility, but its former namespace-wide read permission is narrowed to the API's own prefix. This closes the alternate login path that otherwise lets the API read BFF secrets. Existing tokens using that policy are affected immediately when the ACL changes; verify that no unrecorded consumer depends on the old `kv/homechef/<other-path>` layout before rollout.

The bootstrap ConfigMap renders the ACLs and Kubernetes auth bindings. Its content hash forms the bootstrap Job name, so changing the declarations creates a new idempotent reconciliation Job. The app whitelist also renders each namespaced SecretStore. Existing API permissions were already persistent; this change adds the missing BFF declaration and completes direct API/worker network access.

## Trust boundary and networking

Assets are app credentials and encryption keys. A compromised API, BFF, another application, or an unintended service account must not read another app's prefix. Kubernetes auth binds the exact service account and namespace; ACLs scope paths; NetworkPolicy scopes pod labels and destination port; Istio admits the API's mesh principal. A pod label alone does not authorize reading a secret.

Direct ingress to OpenBao and egress from HomeChef select `app.kubernetes.io/name: homechef-api` in `homechef`, covering API and worker. Destination is OpenBao pods on TCP 8200. Add the ambient identity `cluster.local/ns/homechef/sa/homechef-api`. Do not admit the whole HomeChef namespace or Raft port 8201. The BFF continues using ESO and receives no direct network allowance. Existing other-product networking is unchanged.

## Rollout and verification

Production context: account `unidevidp@gmail.com`, project `tesseracthub-480811`, context `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`. Owning Argo CD applications: `openbao`, `openbao-namespace`, and `homechef-istio`.

Commit the scoped configuration/tests/runbook, create a PR, pass CI, and deploy through those GitOps applications. Do not include the earlier uncommitted inventory files unless requested. No imperatively written policy is needed.

Post-deployment verification must include:

1. Bootstrap Job succeeds, applications are Synced/Healthy, and both namespaced SecretStores are Ready.
2. Authenticate as each exact app service account using short-lived Kubernetes tokens, keeping JWTs/OpenBao tokens in memory and revoking test tokens afterward. The BFF identity must not authenticate as the API role, and an unrelated identity must fail both.
3. Query `sys/capabilities-self` without reading secret values. Each role must have read on its own data prefix, read/list on its metadata prefix, and deny on the other app, `kv/data/platform/*`, another namespace, all write/delete/destroy paths, and administrative endpoints. Test `read-homechef` too, because alternate roles matter.
4. Verify API and worker connectivity using their existing pod identities; API's own read path may return 404 until data is migrated, which is different from 403. The current app image still uses GCP, so successful login is a permission test, not proof that the application has switched providers. Confirm a non-allowed HomeChef workload cannot connect directly.
5. Confirm existing ExternalSecrets remain Ready against GCP and login/API/worker health is unchanged. Migration and provider switching are a separate step.

If OpenBao is unavailable, no new application dependency has been enabled here: current workloads still use GCP/Kubernetes Secrets. The bootstrap Job retries and reports failure; do not work around a failed reconciliation by broadening ACLs.

Rollback is a Git revert through the same owners, but note that bootstrap only upserts: removing a whitelist entry does not delete its previously persisted OpenBao role/policy. To withdraw BFF access, reconcile its policy to explicit deny first; deleting raft roles/policies is a separate controlled action. Do not blindly revert the legacy narrowing, which would restore cross-app reads. No new workloads/storage are added; cost is limited to the existing reconciliation job and token operations.

## Local validation

`python3 -m pytest tests/test_homechef_openbao_access.py -q` exercises rendered ACL/role/store boundaries and the rendered ingress, ambient principal and Kustomize egress rules. Each behavior was observed failing before its change. Helm lint passes for both changed charts; Ruff validates the test module. Live post-deployment tests run after the approved rollout.
