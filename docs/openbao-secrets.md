# OpenBao — the cluster's secret store

OpenBao v2.6.1, three raft nodes in the `openbao` namespace, auto-unsealed by
Cloud KMS. External Secrets Operator reads from it and projects Kubernetes
Secrets into application namespaces. Applications never hold an OpenBao token.

| | |
|---|---|
| Namespace | `openbao` |
| ArgoCD project | `security` |
| Charts | `charts/thirdparty/openbao`, `charts/apps/openbao-namespace` |
| API | `http://openbao.openbao.svc:8200` (in-cluster only, no Ingress) |
| KV mount | `kv/` (v2) |
| Unseal | `seal "gcpckms"` → `tesseract-prod-in-keyring/openbao-unseal-key` |
| Recovery keys | GCP Secret Manager, `prod-openbao-recovery-keys` |
| Snapshots | `gs://tesseract-prod-backups-in/openbao/`, daily 03:00 UTC, 30 days |

## There is no OpenBao Kubernetes operator

`bao operator` is a CLI command group — `init`, `unseal`, `raft`, `rekey`,
`generate-root`. It is not a controller and there is nothing to install for it.
The supported Kubernetes deployment is the official `openbao/openbao` Helm
chart, which is what `charts/thirdparty/openbao` wraps (chart 0.29.1, app
v2.6.1).

There *is* a separate `openbao-secrets-operator`, a fork of vault-secrets-operator
that syncs OpenBao paths into Kubernetes Secrets. We do not use it: ESO already
runs here, already owns every ExternalSecret in the estate, and its Vault
provider speaks OpenBao's API unchanged. A second secret-syncing controller
would mean two reconcile loops racing over the same Secrets.

## Trust chain

The point of the design is that nothing in the cluster holds a credential that
unlocks everything.

1. **Cloud KMS holds the seal key.** OpenBao's own service account reaches it
   through Workload Identity. A stolen PVC or raft snapshot is ciphertext
   without `roles/cloudkms.cryptoKeyDecrypter` on that key.
2. **Auto-unseal, because every node is Spot.** A preempted node on a manually
   unsealed cluster means someone unsealing three pods at 3am. With `gcpckms`
   a restarted pod is ready on its own.
3. **The root token is never stored.** The bootstrap Job initialises the
   cluster, writes the *recovery* keys to Secret Manager, applies the config,
   then calls `auth/token/revoke-self`. Day-2 admin access is minted from the
   recovery keys via `bao operator generate-root` — a deliberate, auditable act.
4. **Applications authenticate as themselves.** Kubernetes auth roles bind a
   named ServiceAccount in a named namespace to a policy scoped to one KV path
   prefix. ESO mints a token for the *application's* ServiceAccount, so the
   identity reading a secret is the identity that will consume it.

Both the recovery keys and the seal key live in GCP. GCP Secret Manager stays
the root of trust; OpenBao is the working store everything else reads.

## Authorization model

Two objects per consumer, both declared in `charts/thirdparty/openbao/values.yaml`
and applied by the bootstrap Job on every sync:

```yaml
bootstrap:
  policies:
    - name: read-homechef
      hcl: |
        path "kv/data/homechef/*"     { capabilities = ["read"] }
        path "kv/metadata/homechef/*" { capabilities = ["read", "list"] }
  kubernetesRoles:
    - name: read-homechef
      serviceAccounts: ["homechef-api", "homechef-worker"]
      namespaces: ["homechef"]
      policies: ["read-homechef"]
      ttl: 1h
```

Rules that are not negotiable:

- **One path prefix per policy**, named after the namespace. A policy that can
  read `kv/data/*` makes the whole model decorative.
- **Never `serviceAccounts: ["*"]`.** That grants the role to every pod in the
  namespace, including anything that gets scheduled there later.
- **Read only.** Nothing in the cluster writes to `kv/`; humans and CI do.

### Wiring an application to it

Put a `SecretStore` — namespaced, not cluster-scoped — in the application's own
chart, authenticating as the application's ServiceAccount:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: openbao
  namespace: homechef
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc:8200"
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: read-homechef
          serviceAccountRef:
            name: homechef-api
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: homechef-api-db
  namespace: homechef
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: SecretStore
  target:
    name: homechef-api-db
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        # kv/data/ is implied by `path: kv` + `version: v2`.
        key: homechef/api/db
        property: password
```

The namespace also has to be added to `allowedSources` and `allowedPrincipals`
in `charts/apps/openbao-namespace/values.yaml`, or ESO's connection is dropped
at L3 before any of this matters.

The `ClusterSecretStore` named `openbao-secret-store` exists for shared
platform credentials only. It authenticates as ESO's own identity, so anything
it can read every namespace can request — which is why its policy stops at
`kv/data/platform/*`.

## Guarding

- Namespace is ambient mesh with PSA `restricted`. `PeerAuthentication` is
  `PERMISSIVE`, not STRICT: `external-secrets` is not mesh-enrolled, so ESO
  dials in plaintext with no SPIFFE identity and STRICT would reject every
  read. Enrol ESO in ambient and this goes to STRICT.
- `default-deny` NetworkPolicy. Only `external-secrets` may reach 8200;
  `monitoring` may reach it for `/v1/sys/metrics`. Port 8201 (raft) is
  intra-namespace only — a client that reaches it talks to the storage layer.
- `AuthorizationPolicy` allow-list by source namespace on top, so a caller must
  pass both. It is deliberately L4 — the namespace is ambient with no waypoint,
  so ztunnel enforces the policy and cannot evaluate an `operation.paths`
  condition; an ALLOW policy whose only rule is L7 evaluates as deny-all.
- No Ingress, no Gateway route, no Cloudflare record. The UI is ClusterIP and
  reached by `kubectl port-forward`.
- Read-only root filesystem, all capabilities dropped, non-root, seccomp
  `RuntimeDefault`.
- Audit device on its own PVC at `/openbao/audit/audit.log`, declared as an
  `audit "file" "file"` stanza in the server config. 2.6 rejects
  `POST /v1/sys/audit/file`, so it cannot be enabled from the bootstrap Job.
- The Agent injector and CSI provider are both disabled: each is a cluster-wide
  mutating path we have no use for while ESO is the reader.

## Prerequisites — already applied

Three GCP service accounts, the KMS key, the recovery-key secret and two IAM
grants. Nothing in the chart creates them; without them the pods crash-loop on
seal init.

**These were created by CLI on 2026-08-13 and imported into Terraform state**
(`03-storage` and `06-workload-identity`), so both stacks plan clean for
OpenBao. The commands are kept here for a rebuild from scratch.

```bash
PROJECT=tesseracthub-480811

# 1. Service accounts
gcloud iam service-accounts create openbao --project="$PROJECT" \
  --display-name="OpenBao Server" \
  --description="Auto-unseal via Cloud KMS for the openbao StatefulSet"
gcloud iam service-accounts create openbao-bootstrap --project="$PROJECT" \
  --display-name="OpenBao Bootstrap" \
  --description="Stores OpenBao recovery keys at cluster initialisation"
gcloud iam service-accounts create openbao-snapshot --project="$PROJECT" \
  --display-name="OpenBao Snapshot" \
  --description="Writes and prunes raft snapshots in the backups bucket"

# 2. Workload Identity bindings
for sa in openbao openbao-bootstrap openbao-snapshot; do
  gcloud iam service-accounts add-iam-policy-binding \
    "${sa}@${PROJECT}.iam.gserviceaccount.com" --project="$PROJECT" \
    --role=roles/iam.workloadIdentityUser \
    --member="serviceAccount:${PROJECT}.svc.id.goog[openbao/${sa}]"
done

# 3. Unseal key. NOT via `terraform apply` — the 03-storage stack has unrelated
#    drift (it plans ~29 creates for resources that already exist), so applying
#    it to get one key is not safe. Create by CLI, then import.
#    destroy_scheduled_duration is immutable and KMS never frees a key name, so
#    it must be right at creation: 30 days, matching tfvars.
gcloud kms keys create openbao-unseal-key --project="$PROJECT" \
  --location=asia-south1 --keyring=tesseract-prod-in-keyring \
  --purpose=encryption --protection-level=software \
  --rotation-period=7776000s --next-rotation-time="$(date -u -v+90d +%Y-%m-%dT%H:%M:%SZ)" \
  --destroy-scheduled-duration=2592000s \
  --labels=environment=prod,managed-by=terraform,project=tesseracthub,region=in,tier=infrastructure,purpose=openbao-unseal
# Both roles: the seal calls cryptoKeys.get before it encrypts, and that is
# not in EncrypterDecrypter — without viewer it fails closed at startup.
for role in roles/cloudkms.cryptoKeyEncrypterDecrypter roles/cloudkms.viewer; do
  gcloud kms keys add-iam-policy-binding openbao-unseal-key --project="$PROJECT" \
    --location=asia-south1 --keyring=tesseract-prod-in-keyring \
    --role="$role" --condition=None \
    --member="serviceAccount:openbao@${PROJECT}.iam.gserviceaccount.com"
done

# 4. Recovery-key secret. Pre-created so the bootstrap Job needs no
#    project-level Secret Manager role. user-managed replication pinned to
#    asia-south1 like every other secret here; the field is immutable.
gcloud secrets create prod-openbao-recovery-keys \
  --project="$PROJECT" --replication-policy=user-managed --locations=asia-south1 \
  --labels=environment=prod,managed-by=terraform,project=tesseracthub,region=in,tier=infrastructure,type=encryption
for role in roles/secretmanager.viewer roles/secretmanager.secretVersionAdder; do
  gcloud secrets add-iam-policy-binding prod-openbao-recovery-keys \
    --project="$PROJECT" --role="$role" \
    --member="serviceAccount:openbao-bootstrap@${PROJECT}.iam.gserviceaccount.com"
done

# 5. Snapshot bucket. --condition=None is required: the bucket policy already
#    carries conditional bindings, and gcloud refuses to guess non-interactively.
gcloud storage buckets add-iam-policy-binding gs://tesseract-prod-backups-in \
  --project="$PROJECT" --role=roles/storage.objectAdmin --condition=None \
  --member="serviceAccount:openbao-snapshot@${PROJECT}.iam.gserviceaccount.com"
```

### Importing them into Terraform state

The tfvars entries exist (`kms_keys`, `secrets`, `service_accounts`), so the
CLI-created objects must be imported or the next apply tries to create them
again and fails on "already exists".

```bash
cd terraform-new/stacks/03-storage && terraform init
VF=../../environments/prod/terraform.tfvars
P=tesseracthub-480811
KEY=projects/$P/locations/asia-south1/keyRings/tesseract-prod-in-keyring/cryptoKeys/openbao-unseal-key
ROLE=roles/cloudkms.cryptoKeyEncrypterDecrypter
MEM=serviceAccount:openbao@$P.iam.gserviceaccount.com

terraform import -var-file=$VF 'google_kms_crypto_key.keys["openbao-unseal-key"]' "$KEY"
terraform import -var-file=$VF "google_kms_crypto_key_iam_member.key_members[\"openbao-unseal-key-$ROLE-$MEM\"]" "$KEY $ROLE $MEM"
terraform import -var-file=$VF 'google_secret_manager_secret.secrets["prod-openbao-recovery-keys"]' "projects/$P/secrets/prod-openbao-recovery-keys"

cd ../06-workload-identity && terraform init
for sa in openbao openbao-bootstrap openbao-snapshot; do
  terraform import -var-file=$VF "google_service_account.workload_identity[\"$sa\"]" \
    "projects/$P/serviceAccounts/$sa@$P.iam.gserviceaccount.com"
  terraform import -var-file=$VF "google_service_account_iam_member.workload_identity_binding[\"$sa-openbao-$sa\"]" \
    "projects/$P/serviceAccounts/$sa@$P.iam.gserviceaccount.com roles/iam.workloadIdentityUser serviceAccount:$P.svc.id.goog[openbao/$sa]"
done
terraform import -var-file=$VF \
  'google_storage_bucket_iam_member.bucket_access["openbao-snapshot-tesseract-prod-backups-in-roles/storage.objectAdmin"]' \
  "b/tesseract-prod-backups-in roles/storage.objectAdmin serviceAccount:openbao-snapshot@$P.iam.gserviceaccount.com"
for role in roles/secretmanager.viewer roles/secretmanager.secretVersionAdder; do
  terraform import -var-file=$VF \
    "google_secret_manager_secret_iam_member.secret_access[\"openbao-bootstrap-prod-openbao-recovery-keys-$role\"]" \
    "projects/$P/secrets/prod-openbao-recovery-keys $role serviceAccount:openbao-bootstrap@$P.iam.gserviceaccount.com"
done
```

`06-workload-identity` then plans clean for OpenBao. Three lines remain in the
`03-storage` plan, none of them real drift:

- the key and the secret show `labels` being added. The google provider v5
  splits `labels` (Terraform-owned) from `effective_labels` (all of them), and
  import populates only the latter — so the first apply merely claims labels
  that are already on the object. Verify with `gcloud kms keys describe` before
  assuming otherwise.
- `google_kms_crypto_key_iam_member.secret_manager_service_agent["openbao-unseal-key"]`
  will be created. The module grants the Secret Manager service agent
  encrypt/decrypt on *every* `ENCRYPT_DECRYPT` key with no per-key opt-out. It
  was left uncreated rather than hand-granted on the unseal key; an apply adds
  it.

Then commit and let ArgoCD sync. The `security` app-of-apps brings up the
namespace (wave -5), the bootstrap script ConfigMap (wave -1), and the
StatefulSet and the bootstrap Job together in wave 0. The Job is a `Sync` hook,
not `PostSync`: a fresh cluster is uninitialised, so no pod ever passes its
readiness probe and a PostSync hook would never fire. Its ConfigMap is a plain
resource — as a hook it would hang in `hookPhase: Running` forever, since
ArgoCD has no completion signal for a ConfigMap.

## Day-2

```bash
export KUBECONFIG=~/.kube/gke-prod

# Cluster health. The image has no curl; use the bao CLI in the pod.
kubectl exec -n openbao openbao-0 -- bao status
kubectl exec -n openbao openbao-0 -- bao operator raft list-peers   # needs a token

# Bootstrap Job output — the only place init and policy application are logged.
kubectl logs -n openbao job/openbao-bootstrap

# UI / CLI from a laptop.
kubectl port-forward -n openbao svc/openbao 8200:8200
```

**Getting an admin token.** There is no stored root token. Fetch a recovery key
share, then:

```bash
gcloud secrets versions access latest --secret=prod-openbao-recovery-keys \
  --project=tesseracthub-480811 | jq -r '.recovery_keys_b64[]'
bao operator generate-root -init          # prints nonce + one-time password
bao operator generate-root -nonce=<nonce> # once per share, up to the threshold of 3
bao operator generate-root -decode=<encoded-token> -otp=<otp>
```

Revoke it (`bao token revoke -self`) when you are done.

**Writing a secret.**

```bash
bao kv put kv/homechef/api/db password=...
```

**Restoring from a snapshot.** The snapshot is sealed with the same KMS key, so
restoring needs the key, not the recovery shares:

```bash
gcloud storage cp gs://tesseract-prod-backups-in/openbao/<date>/<file>.snap .
bao operator raft snapshot restore -force <file>.snap
```

## Auto-upgrades (Kargo)

Version bumps are not hand-edited. The `openbao` Warehouse in `kargo-infra`
watches both upstreams and the `openbao-prod` Stage auto-promotes:

| | |
|---|---|
| Warehouse | `kargo-manifests/projects/infra/warehouses/openbao.yaml` |
| Stage | `kargo-manifests/projects/infra/stages/openbao-prod.yaml` |
| Chart | `https://openbao.github.io/openbao-helm`, `>=0.29.1 <0.30.0` |
| Image | `quay.io/openbao/openbao`, `>=2.6.1 <3.0.0` |
| Poll | hourly, `autoPromotionEnabled: true` |

On new freight the Stage clones `tesserix-k8s`, runs `helm-update-chart`
against `charts/thirdparty/openbao` (which bumps the dependency, rewrites
`Chart.lock` and re-vendors the tarball), writes the image tag into
`values.yaml` and `Chart.yaml`, commits, pushes, then runs `argocd-update` and
waits up to 30m for the app to go Healthy.

Its own warehouse rather than a subscription on `platform-tools`, because a
Warehouse emits one Freight covering all its subscriptions: folding OpenBao in
would let a stuck cert-manager upgrade block a security patch to the secret
store, and vice versa.

Four things that make this safe to leave unattended, and are the things to
check first if it ever isn't:

1. **`helm-update-chart`, not `yaml-update` on `targetRevision`.** The `openbao`
   Application deploys by `path`, so its `targetRevision` is a git ref. Writing
   a chart version there breaks the app with `unable to resolve '0.29.1' to a
   commit SHA` — the exact bug that hit the argocd app in kargo-manifests
   `fec0cf2`.
2. **The Application carries `kargo.akuity.io/authorized-stage`.** Without it
   the last step fails as unauthorized *after* the commit has landed, leaving
   git ahead of the cluster until ArgoCD's next poll.
3. **The ranges are tight on purpose.** openbao-helm is 0.x, where minors are
   semver-breaking (0.28 → 0.29 moved values under `server.`), so the chart is
   pinned to the current *minor*. The image is pinned to the current major:
   2.x → 3.x will change the storage format, and a raft migration is not
   something to wake up to. Widening either is deliberate human work.
4. **A rolling restart is only safe because the seal is `gcpckms`.** With a
   manual seal, every auto-upgrade would strand three sealed pods.

Bumping across a range boundary: widen `semverConstraint` in the warehouse,
read the upstream changelog for moved values, and let the promotion run.

## Adopting it — order of migration

OpenBao does not replace GCP Secret Manager overnight, and it should not: the
recovery keys and the seal key have to live outside it.

1. New services write their secrets to `kv/<namespace>/<app>/<name>` and ship a
   namespaced `SecretStore` from day one.
2. Existing services move one namespace at a time — add the policy and role,
   copy the values across, flip `secretStoreRef` from `gcp-secret-store` to the
   namespace's `openbao` store, confirm the Secret still reconciles, then delete
   the GCP secret.
3. `gcp-secret-store` stays for good, holding exactly three things: the recovery
   keys, the CI tokens ArgoCD itself needs before OpenBao is up, and the
   `@tesserix/web` / GHCR credentials CI uses outside the cluster.

Bootstrap ordering is the reason for rule 3. Anything needed to *start* the
cluster cannot be stored in something the cluster starts.

## Gotchas

1. **The bootstrap Job is the only way config is applied.** A policy added to
   `values.yaml` lands on the next sync, not on `helm template`. If the Job
   fails, ArgoCD reports the sync failed — read its logs before anything else.
2. **If the `bootstrap` Kubernetes auth role is ever deleted, the Job cannot get
   back in.** Recovery is `bao operator generate-root` with the recovery keys,
   then re-creating the role by hand.
3. **Never set `audience` on a Kubernetes auth role.** ESO mints tokens with the
   API server's default audience; a mismatch fails the login with an opaque
   `invalid role name` that says nothing about audiences.
4. **`node_id` must not appear in the raft stanza.** `setNodeId: true` supplies
   it as `BAO_RAFT_NODE_ID`; a literal in the HCL wins and gives all three pods
   the same id, which raft accepts and then behaves strangely about.
5. **Read-only root filesystem needs a `/tmp` emptyDir.** The entrypoint copies
   the config to `/tmp/storageconfig.hcl` and seds it in place. The chart mounts
   `/home/openbao` itself — mounting it again is a duplicate-volume error.
6. **The liveness probe is off on purpose.** `/v1/sys/health` returns 503 on a
   standby node, so enabling it restarts every follower in a loop.
7. **The GKE control plane needs its own egress rule.** It sits at
   `172.16.0.0/28`, inside the RFC1918 range the general HTTPS egress rule
   excludes, and both `service_registration` and the TokenReview behind
   Kubernetes auth go through it.
