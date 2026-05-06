# Distroless Migration Runbook — Go services

This runbook documents how to migrate any tesserix Go service to the
**`ghcr.io/tesserix/base-distroless-static`** runtime base, end to end:
Dockerfile change → CI build → Kargo discovery → ArgoCD rollout →
verification. Every Go-based product (HomeChef, FanZone, mark8ly,
DevAI, GameVerse, StockPilot, Bookkeeping, Guardix, blog, social,
scrapper, …) should follow the same lifecycle so the runtime base is
uniform across the cluster.

The reference migration that established this pattern is **mark8ly**:
`auth-bff`, `otto`, `platform-api`, `marketplace-api` — all four Go
services moved from `base-alpine-runtime` to `base-distroless-static`
in a single PR. Use those Dockerfiles as the template.

## Why distroless

| | `base-alpine-runtime` | `base-distroless-static` |
|---|---|---|
| Upstream | `alpine:3.23` | `gcr.io/distroless/static:nonroot` |
| Image size | ~10 MB + binary | ~2 MB + binary |
| Shell | yes (`/bin/sh`, `apk`) | **no** |
| Package manager | yes (`apk`) | **no** |
| PID-1 init | tini | none — Go runtime handles SIGTERM |
| Default uid | 10001 | 65532 (nonroot) |
| CVE surface | larger (alpine + busybox) | minimal (libc + ca-certs + tzdata) |

Go binaries built by `base-go-builder` are statically linked
(`CGO_ENABLED=0` baked in), so distroless/static is a drop-in runtime.

## When you can migrate

A Go service is safe to move to distroless if **all** of these hold:

- Build uses `base-go-builder` (or any builder with `CGO_ENABLED=0`).
- The container runs a Go binary as PID 1 — no shell entrypoints, no
  multi-process supervisors, no init scripts.
- Healthchecks are HTTP/TCP K8s probes, not in-container `wget`/`curl`.
- Sidecars/init containers that need a shell (`carrier-iam-bootstrap`,
  cron `tracking-sync`, etc.) reference *other* images
  (`google/cloud-sdk:slim`, `curlimages/curl`) — those keep their
  current base, only the *app* image changes.

If any of those don't hold, stay on `base-alpine-runtime`.

## The Dockerfile change

Diff is small and mechanical. Replace every runtime stage:

```diff
-FROM ghcr.io/tesserix/base-alpine-runtime:latest AS server
+FROM ghcr.io/tesserix/base-distroless-static:latest AS server
 COPY --from=build --chown=10001:10001 /out/server /server
 COPY --from=build --chown=10001:10001 /out/migrate /migrate
 EXPOSE 8080
-# base-alpine-runtime's ENTRYPOINT is already `tini --`.
 CMD ["/server"]
```

Key points:

- Keep `--chown=10001:10001` on the COPY directives. Go binaries are
  mode `0755`, so any K8s `runAsUser` can execute them; the chown is
  for hygiene only.
- Do **not** add `USER`. Distroless's image-level user is `nonroot`
  (uid 65532), but K8s `securityContext.runAsUser` in the Helm chart
  overrides it. Don't fight that.
- Drop tini-related comments. Go's runtime handles `SIGTERM` via
  `signal.Notify` and reaps any goroutine-spawned children — no PID-1
  wrapper needed.
- Multi-binary stages (server + migrate + seed + …) all stack on the
  same distroless base. K8s `command:` in the chart picks which binary
  runs at startup — paths in the chart don't change.

For a fully-worked example, see the four mark8ly Dockerfiles:

- [`mark8ly/services/auth-bff/Dockerfile`](https://github.com/tesserix/mark8ly/blob/main/services/auth-bff/Dockerfile)
  — server + migrate
- [`mark8ly/services/otto/Dockerfile`](https://github.com/tesserix/mark8ly/blob/main/services/otto/Dockerfile)
  — single server binary
- [`mark8ly/services/platform-api/Dockerfile`](https://github.com/tesserix/mark8ly/blob/main/services/platform-api/Dockerfile)
  — server + migrate + seed + backfill-vendors
- [`mark8ly/services/marketplace-api/Dockerfile`](https://github.com/tesserix/mark8ly/blob/main/services/marketplace-api/Dockerfile)
  — runtime (`/usr/local/bin/marketplace-api`) + migrate

## What you do NOT need to change

- **Helm charts in tesserix-k8s.** Binary paths are unchanged
  (`/server`, `/migrate`, `/usr/local/bin/marketplace-api`, …) so
  `command:` and `args:` keep working.
- **K8s `securityContext.runAsUser`.** mark8ly's three different uids
  (auth-bff: 10002, platform/marketplace: 10001, otto: 1000) all
  continue to work because binary mode is `0755`.
- **Kargo `Warehouse`.** Tag pattern `^main-[a-f0-9]{7,12}$` is
  identical between alpine and distroless builds; the manifest
  format (single-arch Docker v2 vs multi-arch OCI index) is whatever
  the existing CI workflow produces — don't change it as part of the
  migration.

## End-to-end lifecycle (per product)

This is the same lifecycle every product has to follow once it's
onboarded into Kargo (i.e. has a `kargo-<product>` Project). Use it
verbatim.

### 1. Update Dockerfiles

For each Go service in `services/<svc>/Dockerfile`, replace
`base-alpine-runtime` with `base-distroless-static` per the diff above.
Keep build stages (`base-go-builder`) untouched.

### 2. Local sanity check

```bash
cd services/<svc>
docker build --target server -t test-distroless .
docker run --rm --read-only test-distroless --help 2>&1 | head -5
```

The container should start, print help, and exit 0. If the binary
can't find a runtime dependency (likely a glibc lib pulled in by a
cgo dependency), abort the migration for that service and stay on
alpine.

### 3. Public/build/private cycle (mandatory for tesserix org)

```bash
# 1. Make repo public so CI minutes are free
gh repo edit tesserix/<repo> --visibility public --accept-visibility-change-consequences

# 2. Push — CI builds + pushes to GHCR with main-<sha7> tag
git push origin main

# 3. Watch CI green
gh run list --repo tesserix/<repo> --limit 5
gh run view <run-id> --repo tesserix/<repo>

# 4. Make private once green
gh repo edit tesserix/<repo> --visibility private --accept-visibility-change-consequences
```

Wait for *all* `Build & push` jobs to succeed — not just `Go (...)`
which only checks compile/test. The push jobs are what actually
publish the image.

### 4. Prime GAR mirror cache

The `ghcr-remote` repository in GAR is a pull-through cache: it only
exposes tags it has fetched. The first time *anything* asks for
`main-<sha>`, GAR fetches from GHCR. Kargo's tags-list discovery
**won't see a tag GAR hasn't been asked for**, so prime the cache
explicitly:

```bash
TOKEN=$(gcloud auth print-access-token)
SHA=$(git rev-parse --short=7 HEAD)        # or whatever CI tagged

for svc in <list-of-image-names>; do
  http=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://asia-south1-docker.pkg.dev/v2/tesseracthub-480811/ghcr-remote/tesserix/${svc}/manifests/main-${SHA}")
  echo "${svc}: HTTP $http"
done
```

Every line should print `HTTP 200`. A `404` means CI hasn't pushed
yet; a `403` means the kargo-controller's GCP SA isn't bound to
`roles/artifactregistry.reader` on this project (re-check Workload
Identity).

### 5. Trigger Kargo Warehouse refresh

```bash
export KUBECONFIG=~/.kube/gke-prod
kubectl -n kargo-<product> annotate warehouse services \
  kargo.akuity.io/refresh=$(date +%s) --overwrite
```

Within ~30 s, the Warehouse should re-discover and emit a new Freight:

```bash
kubectl -n kargo-<product> get freight \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns="NAME:.metadata.name,IMAGES:.images[*].tag" \
  --no-headers | tail -3
```

The newest line should show `main-<sha>` for every service in the
project. The Stage(prod) auto-promotes immediately, producing a
`Promotion` with phase `Succeeded`.

### 6. Verify the rollout

```bash
# All Apps land on the new tag
for app in $(kubectl -n argocd get apps -l product=<product> -o name | cut -d/ -f2); do
  tag=$(kubectl -n argocd get app $app -o jsonpath='{.spec.source.helm.parameters[?(@.name=="image.tag")].value}')
  sync=$(kubectl -n argocd get app $app -o jsonpath='{.status.sync.status}')
  health=$(kubectl -n argocd get app $app -o jsonpath='{.status.health.status}')
  printf "%-40s tag=%-12s sync=%-12s health=%s\n" "$app" "$tag" "$sync" "$health"
done

# Pods are running the new image with restart count 0
kubectl -n <product-ns> get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}' \
  | grep "<svc>"
```

Both must show `main-<sha>` and pods must be `Running 1/1` with
`restartCount: 0`. If a pod is `CrashLoopBackOff`, **read its logs
before assuming the migration is the cause** — the same Kargo
promotion will pick up genuinely-broken images too.

## Phase plan across the org

Recommended onboarding order (smallest blast radius first; depends on
Kargo Project already existing for that product):

1. **mark8ly** — done 2026-05-07. 4 Go services
   (`auth-bff`, `otto`, `platform-api`, `marketplace-api`) on
   distroless-static. Reference Dockerfiles for new migrations.
2. **homechef** — done 2026-05-07. 1 Go service (`homechef-api`)
   on distroless-static; product also onboarded into Kargo
   (`kargo-homechef` Project, 5 ArgoCD Apps, 5 image subscriptions).
   The shared `tesseract-nexus/global-services/auth-bff` image is
   intentionally OUT of scope here — same image is consumed by
   `devai-auth-bff`, so it will land under a separate
   `kargo-shared-services` Project alongside DevAI.
3. **fanzone** — 23 services, multi-arch images. The Warehouse already
   uses `platform: linux/amd64`; that's orthogonal to distroless — the
   amd64 variant of the image still has `CGO_ENABLED=0` static
   binaries. No Kargo change needed; just the Dockerfile sweep.
4. **bookkeeping** — 6 Go services (`bka-auth/core/customer/invoice/report/tax`).
   Needs Kargo onboarding first.
5. **gameverse** — Rust (not Go). Distroless still applies because
   the Rust builder uses `openssl-libs-static` to produce a static
   musl binary, but this runbook is Go-specific; will need a Rust
   addendum before rolling.
6. **shared `auth-bff` (kargo-shared-services)** — the
   `tesseract-nexus/global-services/auth-bff` image consumed by
   HomeChef + DevAI. Standing up this Project lets a single
   promotion update both products in lock-step.
7. **devai, stockpilot, blog, social, scrapper, guardix, tesserix-blog** —
   onboard each into Kargo first
   (see [`adding-a-project.md`](https://github.com/tesserix/kargo-manifests/blob/main/docs/adding-a-project.md)),
   then run this runbook. Several of these are Python (devai, stockpilot,
   scrapper) so they're out of scope for *Go* distroless migration —
   they'd use `base-python-runtime-3.13` instead.

## Common pitfalls

- **`status` is read-only in zsh.** If you copy a polling script that
  uses `status=$(...)` it dies with `read-only variable`. Rename to
  `runState` or `http`.
- **GAR mirror returns stale tag list.** Always prime the cache for a
  brand-new tag before triggering Warehouse refresh — otherwise
  Kargo's discovery comes back with the previous list and "Freight
  composed of the newest artifacts already exists".
- **Don't switch a multi-arch image to single-arch as part of this
  migration.** That's a separate change, has its own Kargo
  consequence (gotcha #10 in the kargo Phase 1 retrospective: drop
  `platform: linux/amd64` from the Warehouse subscription), and is
  easy to confuse with a distroless rollback.
- **Don't add a `USER` directive.** Distroless's `nonroot` (uid 65532)
  is the image default; K8s `runAsUser` overrides it. Adding `USER
  10001` in the consumer Dockerfile creates a phantom `/etc/passwd`
  expectation distroless doesn't satisfy.
- **carrier-iam-bootstrap / curl cron jobs.** Those reference
  external images (`google/cloud-sdk:slim`, `curlimages/curl`), not
  the app image. Leave them alone.

## Cross-references

- Base image catalog: [`base-docker-images/README.md`](https://github.com/tesserix/base-docker-images/blob/main/README.md)
- Distroless source: `base-docker-images/images/distroless-static/Dockerfile`
- Kargo onboarding: [`kargo-manifests/docs/adding-a-project.md`](https://github.com/tesserix/kargo-manifests/blob/main/docs/adding-a-project.md)
- GAR mirror architecture: [`docs/artifact-registry-mirror.md`](./artifact-registry-mirror.md)
