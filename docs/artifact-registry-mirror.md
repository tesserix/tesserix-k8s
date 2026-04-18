# Artifact Registry Remote Mirrors — Setup, Security, and Cost Audit

**Owner:** Infra / Platform
**Date implemented:** 2026-04-18
**Project:** `tesseracthub-480811`
**Region:** `asia-south1`
**Cluster affected:** `tesseract-prod-in-gke`

---

## 1. TL;DR

Four Artifact Registry (AR) **remote repositories** were created in `asia-south1` to
cache container images pulled from public registries and from private GHCR.
The GKE node service account is the only principal granted `roles/artifactregistry.reader`
on these repositories, so pulls are effectively restricted to the production cluster.

Once workloads are migrated to pull from the mirror URLs, image traffic stops flowing
through Cloud NAT, cutting the dominant line item in our GCP networking bill.

| | Before mirror | After mirror (steady state) |
|---|---|---|
| Image pull path | internet → Cloud NAT → node | AR (same region) → node |
| Per-GB cost | **$0.045/GB** NAT data processing | **$0** (same-region, Private Google Access) |
| AR storage cost | — | **$0.10/GB/month** (cached layers only) |

**Observed baseline (Apr 1–17, 2026):** Cloud NAT processed **215 GB received + 36 GB sent** over 7 days — projects to **~1,076 GB/month**. That is ~$45–50/month in NAT data-processing fees, plus repeat cost every time a spot node churns or a Knative service cold-starts.

**Projected savings after full migration:** $25–40/month of NAT fees eliminated, replaced with ~$3–8/month of AR storage. Net **~$20–35/month saved**, scaling down further as spot churn increases.

Savings should be re-measured 30 days after migration via the "Cloud NAT data processing" SKU in the billing console or BigQuery billing export (`billing_export` dataset). See **§7 Verification** below.

---

## 2. Why this was needed

The April 2026 GCP bill showed **$84 in Networking charges** on what is supposed to be a cost-optimised spot-instance cluster. Investigation broke this down as:

| Driver | Cost share |
|---|---|
| Cloud NAT data processing (image pulls + Cloudflared tunnel) | ~$45–50 |
| 2 external L4 forwarding rules (`istio-ingressgateway`, `kong-kong-proxy`) | ~$36 |
| Inter-zone pod traffic, misc | ~$3–5 |

Spot instances save **compute**, not network. They actually increase network cost because every preemption and Knative cold start re-pulls images from the public internet through Cloud NAT. A live `kubectl get pods -A` showed:

- 151 container refs from `ghcr.io`
- 56 refs from `gcr.io` (already free via PGA)
- 36 refs from `docker.io`
- 30 refs from `quay.io`
- Other: `cloudflare/cloudflared`, `lindesvard/*`, `mautic/*`, `growthbook/*` — all on docker.io
- 2 refs from `registry.k8s.io` (kube-system / pause images)

The public-registry pulls are the NAT-metered ones. Mirroring them in-region eliminates the cost.

---

## 3. What was created

All resources live in **project `tesseracthub-480811`**, **location `asia-south1`**.

| Repository ID | Format | Mode | Upstream | Auth |
|---|---|---|---|---|
| `docker-remote` | DOCKER | REMOTE_REPOSITORY | Docker Hub | public |
| `quay-remote`   | DOCKER | REMOTE_REPOSITORY | `https://quay.io` | public |
| `k8s-remote`    | DOCKER | REMOTE_REPOSITORY | `https://registry.k8s.io` | public |
| `ghcr-remote`   | DOCKER | REMOTE_REPOSITORY | `https://ghcr.io` | Secret Manager (`prod-tesserix-ghcr-token`, user `Sam123ben`) |

Mirror hostnames (what Kubernetes manifests should reference):

```
asia-south1-docker.pkg.dev/tesseracthub-480811/docker-remote/...
asia-south1-docker.pkg.dev/tesseracthub-480811/quay-remote/...
asia-south1-docker.pkg.dev/tesseracthub-480811/k8s-remote/...
asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/...
```

### 3.1 Image URL mapping

| Upstream reference | Mirror reference |
|---|---|
| `ghcr.io/tesserix/<repo>:<tag>` | `asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/<repo>:<tag>` |
| `ghcr.io/tesseract-nexus/<repo>:<tag>` | `asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesseract-nexus/<repo>:<tag>` |
| `docker.io/library/redis:8.0-alpine` *(or `redis:8.0-alpine`)* | `asia-south1-docker.pkg.dev/tesseracthub-480811/docker-remote/library/redis:8.0-alpine` |
| `docker.io/<user>/<repo>:<tag>` *(or `<user>/<repo>:<tag>`)* | `asia-south1-docker.pkg.dev/tesseracthub-480811/docker-remote/<user>/<repo>:<tag>` |
| `quay.io/jetstack/cert-manager-controller:<tag>` | `asia-south1-docker.pkg.dev/tesseracthub-480811/quay-remote/jetstack/cert-manager-controller:<tag>` |
| `registry.k8s.io/pause:3.9` | `asia-south1-docker.pkg.dev/tesseracthub-480811/k8s-remote/pause:3.9` |

Notes:
- For Docker Hub, **prepend `library/`** when the image is official (e.g. `redis`, `mongo`, `postgres`, `busybox`) — this is the canonical namespace on Docker Hub.
- `gcr.io` images (88 refs) are already free via Private Google Access — **do not mirror them**. They continue to pull directly from `gcr.io`.

---

## 4. Security model

### 4.1 IAM — who can pull

The mirrors hold **cached copies of private GHCR images**, so they are treated as sensitive. IAM is applied at the **repository level**, not project level, so granting `roles/artifactregistry.reader` elsewhere does not bleed into these repos.

```
Repository: docker-remote / quay-remote / k8s-remote / ghcr-remote
  roles/artifactregistry.reader:
    serviceAccount:849928263410-compute@developer.gserviceaccount.com   # GKE node SA — ONLY principal
```

Verification:

```bash
for repo in docker-remote quay-remote k8s-remote ghcr-remote; do
  gcloud artifacts repositories get-iam-policy "$repo" \
    --project=tesseracthub-480811 --location=asia-south1 \
    --format="value(bindings.role,bindings.members)"
done
```

### 4.2 What this IAM buys us

- **Anonymous pulls: denied.** Unauthenticated request returns HTTP 401.
- **Other-project or random-user pulls: denied.** No `allUsers`, no `allAuthenticatedUsers`, no broad reader at project level.
- **Cross-project service accounts: denied** unless explicitly granted on a repository.
- **Only the GKE node SA can pull.** That SA is bound to Compute Engine instances in the GKE node pool — not assignable to arbitrary users.
- **No one can impersonate the node SA.** `gcloud iam service-accounts get-iam-policy` on the node SA returns an empty policy (no `roles/iam.serviceAccountTokenCreator` bindings), so no user or workload can mint tokens for it.

### 4.3 GHCR upstream credentials

- Stored in **GCP Secret Manager**: `projects/849928263410/secrets/prod-tesserix-ghcr-token/versions/latest`.
- Accessible only to:
  - `service-849928263410@gcp-sa-artifactregistry.iam.gserviceaccount.com` — the AR service agent, to authenticate upstream fetches on our behalf.
- The secret never leaves Google-managed infrastructure; AR uses it server-side when fetching from `ghcr.io`.
- Rotating the GitHub PAT: add a new version to `prod-tesserix-ghcr-token`; AR resolves `versions/latest` automatically.

### 4.4 Defense-in-depth options (future)

If image provenance ever becomes a stronger requirement, layer on:
- **VPC-SC perimeter** around `artifactregistry.googleapis.com` so pulls must originate from inside the VPC even if a principal is compromised.
- **Binary Authorization** on GKE to require attestations on images pulled via the mirror.
- **Container Scanning** (already available in AR) on the `ghcr-remote` repo for vulnerability reporting on cached images.

---

## 5. How to migrate workloads

Two approaches. **Option A is recommended** for this project because it is explicit, auditable in Git, and needs no node pool changes.

### Option A — rewrite image references in Helm charts (recommended)

Update `image:` values under `charts/apps/**/values*.yaml` and any direct Deployment manifests. Suggested mapping script, run from `tesserix-k8s/`:

```bash
# Dry-run — preview matches
grep -rE 'image:\s*(\x27|\x22)?ghcr\.io/tesserix/' charts/apps/

# Apply — ghcr.io/tesserix/*
find charts/apps -name 'values*.yaml' -print0 | \
  xargs -0 sed -i '' -E \
  's#(image:\s*[\x27\x22]?)ghcr\.io/tesserix/#\1asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/#g'

# Apply — ghcr.io/tesseract-nexus/*
find charts/apps -name 'values*.yaml' -print0 | \
  xargs -0 sed -i '' -E \
  's#(image:\s*[\x27\x22]?)ghcr\.io/tesseract-nexus/#\1asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesseract-nexus/#g'
```

Commit the changes, push, let ArgoCD sync. Migrate in waves (e.g. non-critical namespaces first) so any issue affects one service at a time.

### Option B — containerd registry mirror on the node pool (transparent)

GKE 1.32+ supports configuring containerd with a registry mirror via `--containerd-config` on node pool updates. Pods continue to reference upstream URLs (`ghcr.io/...`) and containerd transparently redirects to the mirror.

Pros: zero manifest changes across 64 namespaces.
Cons: needs a node pool rolling restart; adds one more moving part to reason about; GHCR auth config on the node is tricky since containerd needs the pull secret.

This is a good follow-up optimisation once Option A proves stable.

### 5.1 Pull secrets / `imagePullSecrets`

Workloads currently referencing GHCR via a Kubernetes `Secret` of type `kubernetes.io/dockerconfigjson` can drop the secret once migrated — the node SA authenticates with AR automatically using its metadata-server credentials. ArgoCD-managed `imagePullSecrets` entries should be removed in the same PR that rewrites the image URL.

---

## 6. How it was set up (for audit reproducibility)

The exact sequence of actions. A re-runnable script is checked in at [`scripts/setup-artifact-registry-mirror.sh`](../scripts/setup-artifact-registry-mirror.sh).

```bash
# 0. Pre-reqs
gcloud services enable artifactregistry.googleapis.com secretmanager.googleapis.com \
  --project=tesseracthub-480811

# 1. Let AR's service agent read the GHCR PAT secret
gcloud secrets add-iam-policy-binding prod-tesserix-ghcr-token \
  --project=tesseracthub-480811 \
  --member="serviceAccount:service-849928263410@gcp-sa-artifactregistry.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# 2. Public remote repos (no upstream auth)
gcloud artifacts repositories create docker-remote \
  --project=tesseracthub-480811 --location=asia-south1 \
  --repository-format=docker --mode=remote-repository \
  --description="Public Docker Hub mirror — reduces Cloud NAT egress" \
  --remote-repo-config-desc="docker.io mirror" \
  --remote-docker-repo=DOCKER-HUB

gcloud artifacts repositories create quay-remote \
  --project=tesseracthub-480811 --location=asia-south1 \
  --repository-format=docker --mode=remote-repository \
  --description="quay.io mirror — reduces Cloud NAT egress" \
  --remote-repo-config-desc="quay.io mirror" \
  --remote-docker-repo=https://quay.io

gcloud artifacts repositories create k8s-remote \
  --project=tesseracthub-480811 --location=asia-south1 \
  --repository-format=docker --mode=remote-repository \
  --description="registry.k8s.io mirror — reduces Cloud NAT egress" \
  --remote-repo-config-desc="registry.k8s.io mirror" \
  --remote-docker-repo=https://registry.k8s.io

# 3. Authenticated GHCR remote
gcloud artifacts repositories create ghcr-remote \
  --project=tesseracthub-480811 --location=asia-south1 \
  --repository-format=docker --mode=remote-repository \
  --description="ghcr.io mirror (authenticated via prod-tesserix-ghcr-token)" \
  --remote-repo-config-desc="ghcr.io mirror (Sam123ben)" \
  --remote-docker-repo=https://ghcr.io \
  --remote-username=Sam123ben \
  --remote-password-secret-version="projects/849928263410/secrets/prod-tesserix-ghcr-token/versions/latest"

# 4. Restrict pulls to the GKE node service account
for repo in docker-remote quay-remote k8s-remote ghcr-remote; do
  gcloud artifacts repositories add-iam-policy-binding "$repo" \
    --project=tesseracthub-480811 --location=asia-south1 \
    --member="serviceAccount:849928263410-compute@developer.gserviceaccount.com" \
    --role="roles/artifactregistry.reader"
done
```

---

## 7. Verification

### 7.1 Repos exist and are correctly configured

```bash
gcloud artifacts repositories list \
  --project=tesseracthub-480811 --location=asia-south1 \
  --format="table(name.basename(),format,mode,description)"
```

Expected: 4 rows with `REMOTE_REPOSITORY` mode.

### 7.2 Each mirror can resolve an upstream image

```bash
TOKEN=$(gcloud auth print-access-token)
for ref in \
  "docker-remote/library/alpine/manifests/3.19" \
  "quay-remote/jetstack/cert-manager-controller/manifests/v1.15.0" \
  "k8s-remote/pause/manifests/3.9" \
  "ghcr-remote/tesserix/tesserix-blog/manifests/latest"; do
  printf '%-60s ' "$ref"
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    "https://asia-south1-docker.pkg.dev/v2/tesseracthub-480811/$ref"
done
```

Expected: all HTTP 200. Anonymous pulls (`curl` without `Authorization`) must return HTTP 401 — this confirms IAM is enforcing.

### 7.3 Measuring the cost drop

After migrating workloads, compare Cloud NAT data processed before/after:

```bash
# Cloud NAT received bytes, last 7 days
TOKEN=$(gcloud auth print-access-token)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)
curl -sS -H "Authorization: Bearer $TOKEN" \
  "https://monitoring.googleapis.com/v3/projects/tesseracthub-480811/timeSeries?filter=metric.type%3D%22router.googleapis.com%2Fnat%2Freceived_bytes_count%22&interval.startTime=$START&interval.endTime=$END&aggregation.alignmentPeriod=86400s&aggregation.perSeriesAligner=ALIGN_SUM" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
    total=sum(int(p['value'].get('int64Value',0)) for t in d.get('timeSeries',[]) for p in t.get('points',[])); \
    print(f'NAT received (7d): {total/1e9:.2f} GB, monthly projection: {total*30/7/1e9:.2f} GB')"
```

**Baseline (Apr 10–17, 2026, pre-migration):** 215.49 GB received (7d), 923.53 GB/month projected.

Target post-migration: < 100 GB/month (residual traffic is Cloudflared tunnel data-plane + external API calls, not image pulls).

### 7.4 AR storage growth

```bash
gcloud artifacts repositories describe ghcr-remote \
  --project=tesseracthub-480811 --location=asia-south1 \
  --format="value(sizeBytes)"
```

Storage is billed at $0.10/GB/month. Expect 20–80 GB of cached layers once warm.

---

## 8. Rollback

If the mirror misbehaves (e.g. upstream auth breaks), rolling back is straightforward:

1. Revert the Helm `values.yaml` changes that point image URLs at `asia-south1-docker.pkg.dev/...` — workloads go back to pulling from `ghcr.io` / `docker.io` directly.
2. Leave the AR repos in place — they cost ~$0 when not used beyond storage.
3. To fully remove:
   ```bash
   for r in docker-remote quay-remote k8s-remote ghcr-remote; do
     gcloud artifacts repositories delete "$r" \
       --project=tesseracthub-480811 --location=asia-south1 --quiet
   done
   ```

---

## 9. Other networking cost levers (not done in this change)

| Lever | Est. monthly saving | Effort |
|---|---|---|
| Collapse `custom-ingressgateway` + `kong-kong-proxy` into one external L4 LB | $18 | medium — route Kong via Istio or vice versa |
| Audit Cloudflared tunnel egress (8 tunnels × persistent outbound) | $5–15 | low — check whether tunnels carry traffic that could stay internal |
| Move stateful services (MongoDB, Redis) to a single zone | $3–5 | medium — reduces inter-zone $0.01/GB |
| Sample Cloud NAT logs instead of full logging | $1–5 | trivial — one flag on the NAT config |

---

## 10. Appendix — Terraform equivalent (not yet applied)

The setup was done imperatively with `gcloud` to start saving money immediately. Below is the equivalent Terraform so the config can be codified in `terraform-new/stacks/03-storage` (or a new stack) and `terraform import`-ed.

```hcl
locals {
  ghcr_credential = {
    username           = "Sam123ben"
    password_secret_id = "prod-tesserix-ghcr-token"
  }

  public_remotes = {
    "docker-remote" = { public_repository = "DOCKER_HUB",                description = "Public Docker Hub mirror — reduces Cloud NAT egress" }
    "quay-remote"   = { custom_uri        = "https://quay.io",           description = "quay.io mirror — reduces Cloud NAT egress" }
    "k8s-remote"    = { custom_uri        = "https://registry.k8s.io",   description = "registry.k8s.io mirror — reduces Cloud NAT egress" }
  }

  gke_node_sa         = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
  ar_service_agent    = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-artifactregistry.iam.gserviceaccount.com"
}

# Let the AR service agent read the GHCR PAT.
resource "google_secret_manager_secret_iam_member" "ar_reads_ghcr_pat" {
  project   = var.project_id
  secret_id = local.ghcr_credential.password_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.ar_service_agent
}

# Public upstreams — no credentials.
resource "google_artifact_registry_repository" "public_remote" {
  for_each = local.public_remotes

  provider      = google-beta
  project       = var.project_id
  location      = "asia-south1"
  repository_id = each.key
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = each.value.description

  remote_repository_config {
    description = each.value.description

    docker_repository {
      public_repository = try(each.value.public_repository, null)
      custom_repository {
        uri = try(each.value.custom_uri, null)
      }
    }
  }
}

# GHCR — authenticated upstream.
resource "google_artifact_registry_repository" "ghcr_remote" {
  provider      = google-beta
  project       = var.project_id
  location      = "asia-south1"
  repository_id = "ghcr-remote"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "ghcr.io mirror (authenticated via prod-tesserix-ghcr-token)"

  remote_repository_config {
    description = "ghcr.io mirror (Sam123ben)"

    docker_repository {
      custom_repository { uri = "https://ghcr.io" }
    }

    upstream_credentials {
      username_password_credentials {
        username                = local.ghcr_credential.username
        password_secret_version = "projects/${data.google_project.project.number}/secrets/${local.ghcr_credential.password_secret_id}/versions/latest"
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.ar_reads_ghcr_pat]
}

# Grant pull access only to the GKE node SA.
resource "google_artifact_registry_repository_iam_member" "node_sa_reader" {
  for_each = toset(["docker-remote", "quay-remote", "k8s-remote", "ghcr-remote"])

  project    = var.project_id
  location   = "asia-south1"
  repository = each.key
  role       = "roles/artifactregistry.reader"
  member     = local.gke_node_sa

  depends_on = [
    google_artifact_registry_repository.public_remote,
    google_artifact_registry_repository.ghcr_remote,
  ]
}
```

To import the live resources into state:

```bash
terraform import 'google_artifact_registry_repository.public_remote["docker-remote"]' \
  projects/tesseracthub-480811/locations/asia-south1/repositories/docker-remote
terraform import 'google_artifact_registry_repository.public_remote["quay-remote"]' \
  projects/tesseracthub-480811/locations/asia-south1/repositories/quay-remote
terraform import 'google_artifact_registry_repository.public_remote["k8s-remote"]' \
  projects/tesseracthub-480811/locations/asia-south1/repositories/k8s-remote
terraform import google_artifact_registry_repository.ghcr_remote \
  projects/tesseracthub-480811/locations/asia-south1/repositories/ghcr-remote
```

---

## 11. Change history

| Date | Who | Change |
|---|---|---|
| 2026-04-18 | Samyak | Initial setup: 4 remote repos, IAM locked to GKE node SA, audit doc. |
