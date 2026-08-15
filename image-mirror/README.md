# Third-party image mirror

Re-hosts every **non-Google** upstream container image the cluster uses into our
own registry so the cluster never pulls a 3rd-party image from the public
internet — which is what was driving the Cloud NAT data-processing bill.

## Why this exists (the NAT cost)

The cluster is 100% **spot** nodes (`optimized-v2`, `gpu-l4-spot`). Spot nodes
get preempted and replaced constantly, and every replacement node **re-pulls**
the images its pods need. Images pulled from `ghcr.io`, `docker.io`, `quay.io`,
`cr.kagent.dev`, etc. go out through **Cloud NAT** and are billed per-GB
(*Networking → Cloud NAT Data Processing*). On 2026-06-12/13 a burst of such
egress (≈550 GB over two days, mostly large AI images + model pulls in
`support-platform`) spiked the Networking line +104%.

`Private Google Access` is already enabled, so anything served from
**Artifact Registry** (`*.pkg.dev`) or Google registries (`gcr.io`,
`gke.gcr.io`) is reached internally and costs **no** NAT. The fix is therefore:
make every 3rd-party image come from Artifact Registry too.

## How it works

```
 upstream (ghcr.io / docker.io / cr.kagent.dev / ...)
        │  fortnightly GitHub Actions (ubuntu-latest, OFF our network)
        ▼
 ghcr.io/tesserix/third-party/<name>:<tag>          ← we own this copy
        │  AR pull-through repo `ghcr-remote`
        ▼
 asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/third-party/<name>:<tag>
        │  Kargo Warehouse watches this path, promotes new tags
        ▼
 chart image.repository  ← cluster pulls here = Private Google Access = NO NAT
```

- **`images.yaml`** — declarative list of what to mirror + the tag-tracking
  policy per image (see the schema comment at the top of the file).
- **`mirror.py`** — resolves the tag (fixed, or newest-in-`constraint` for
  semver) and `crane copy`s upstream → our GHCR. Idempotent.
- **`.github/workflows/mirror-third-party.yml`** — runs `mirror.py` on the 1st
  and 15th (≈fortnightly) and on manual dispatch. **GitHub-hosted runner on
  purpose** — the upstream bytes are pulled on GitHub's network, never ours.

> ⚠️ The workflow **must** stay on `ubuntu-latest`. Running it on the in-cluster
> ARC runners would move all that egress back onto Cloud NAT.

## Running it

```bash
# Manual full run (Actions tab → "Mirror Third-Party Images" → Run workflow)
gh workflow run mirror-third-party.yml --repo tesserix/tesserix-k8s

# Dry run (resolve tags, copy nothing)
gh workflow run mirror-third-party.yml --repo tesserix/tesserix-k8s -f dry_run=true

# Limit to specific images
gh workflow run mirror-third-party.yml --repo tesserix/tesserix-k8s -f only=keda,grafana,tempo
```

Optional `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` repo secrets avoid Docker Hub
anonymous rate limits; without them anonymous pulls are used.

## Rollout — IMPORTANT sequencing

**A chart must not be repointed before its tag exists in the mirror**, or pods
ImagePullBackOff on the next ArgoCD sync. Order:

1. **Run the mirror once** (full run) and confirm
   `ghcr.io/tesserix/third-party/*` is populated.
2. **Repoint charts** to the AR path (Phase 2 below), one app/group at a time,
   validating with `helm template`.
3. **Wire Kargo** so future upstream releases promote automatically.

## Phase 2 — consuming a mirrored image (per app)

For each chart that pulls a now-mirrored image:

**1. Repoint the chart image** (`charts/apps/<app>/values*.yaml`):

```yaml
image:
  # was: ghcr.io/kedacore/keda
  repository: asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/third-party/keda
  tag: "2.20.1"          # seed; Kargo overwrites on promotion
  pullPolicy: IfNotPresent
```

For Helm **sub-charts** (istio, grafana, cloudnative-pg, external-secrets, …)
set the upstream chart's image override instead — usually
`image.registry`/`image.repository` or `global.imageRegistry`. Point it at
`asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/third-party`.

**2. Add a Kargo image subscription** to the infra warehouse
(`kargo-manifests/projects/infra/warehouses/third-party.yaml`):

```yaml
- image:
    repoURL: asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/tesserix/third-party/keda
    imageSelectionStrategy: SemVer      # or Digest for rolling tags (:latest, :server, cpu-1.8)
    semverConstraint: ">=2.20.0 <2.21.0"
    discoveryLimit: 50
    platform: linux/amd64
```

**3. Add the git write-back step** to the infra stage
(`kargo-manifests/projects/infra/stages/third-party-prod.yaml`) — same shape as
the existing `istio-prod` stage (`git-clone` → `yaml-update` on
`charts/apps/<app>/values.yaml` key `image.tag` → `git-commit` → `git-push` →
`argocd-update`).

**4. Authorize the stage** on the ArgoCD Application
(`argocd/prod/apps/.../<app>.yaml`):

```yaml
metadata:
  annotations:
    kargo.akuity.io/authorized-stage: kargo-infra:third-party-prod
```

and ensure the parent app-of-apps has
`ignoreDifferences: /spec/source/helm/parameters` (already present for the
homechef app-of-apps; add for others as you onboard them).

## Tag policy / safety

`constraint` in `images.yaml` bounds "track latest" so Kargo never jumps a
breaking major/minor unattended (e.g. istio is pinned to `>=1.29 <1.30`). Widen
the range deliberately when you plan an upgrade. Rolling tags (`:latest`,
`:server`, `cpu-1.8`) use Kargo's **Digest** strategy and promote when the
digest behind the tag changes.

## Not mirrored (already NAT-free)

`gcr.io/kubecost1/*`, `gke.gcr.io/*`,
`gcr.io/gke-release/*` (Google-hosted, reached via Private Google Access), and
`ghcr.io/tesseract-nexus/*` + `*.pkg.dev/*` (our own apps, already in AR).
