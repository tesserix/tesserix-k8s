# AX runtime sources

The images in `images.json` are the deployment inputs. `sources.json` pins the
Apache-2.0 upstream revisions. `ax.patch` adds dependency readiness, fail-closed
Substrate initialization and owned runner/snapshot defaults. `substrate.patch`
uses Kubernetes certificate v1 APIs and isolates the runtime under `ax.ate.dev`,
`ax-system`, `/var/lib/ax-ateom-gvisor` and ports 18085/19090. It also contains the
create-only OpenBao bootstrap executable and regression tests.

Recreate source trees with `./scripts/ax/checkout.sh /tmp/ax-build-NEW`.
Run `go test -race ./...`, `go vet ./...` and `go build ./...` in AX. In Substrate,
run the affected ateclient, generated client, podcertcontroller, atecontroller,
atelet, ateompath, deviceplugin and ax-bootstrap package tests. Use ko v0.18.0
with `--platform=linux/amd64 --base-import-paths` for the Go images. Registry:
`asia-south1-docker.pkg.dev/tesseracthub-480811/global/ax-runtime`.

The runner contains AX's `cmd/ax-task-runner`, `runner/antigravity_bootstrap.py`
and the hashed Linux Python dependencies in `runner-requirements.txt`, layered
on the pinned Python image. The actor template explicitly invokes
`/usr/local/bin/ax-task-runner`. Never rely on the base image entrypoint.

After rebuilding, record image digests, then run
`uv run --with pyyaml python scripts/ax/render_runtime.py PATH_TO_PATCHED_SUBSTRATE`.
The renderer preserves the separately authored configuration/state manifests.
Run the AX runtime and Valkey tests and review the rendered Git diff before
rollout. These are maintained compatibility patches, not an upstream release.
