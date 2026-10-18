# Helivanta rollout quota headroom

On 2026-10-18, release `tesserix/helivanta#1241` exposed a namespace admission deadlock. Both document worker deployments retained one surge pod while their scanner freshness checks failed (application issue #1242). The namespace used 11.5 CPU limits; admission rejected a new API pod requesting 0.75 CPU against the 12 CPU quota. The API remained at one available replica of the previous image.

The steady workload limit budget is 10.75 CPU: eight API/shell/worker pods at 0.75 each, ClamAV plus its sidecar at 1.25, two CNPG instances at 1 each, OpenFGA at 1 and NATS at 0.5. Two worker surges add 1.5, and the migration hook adds 0.5: 12.75 CPU. API and shell currently replace in place; ClamAV uses Recreate.

The proposed namespace CPU-limit ceiling is 14, leaving 1.25 CPU above that bound for background jobs and terminating pods. The regression test renders both application charts, includes injected sidecar limits and actual replica/surge settings, and includes the fixed datastore footprint and migration hook. It fails against the previous quota.

This changes admission headroom only. CPU requests, memory limits, per-container limits, replica counts, autoscaling, node pools and scanner security checks stay unchanged. It reserves no additional cluster capacity by itself; admitted work can consume its existing requested resources. The goal is to restore the already configured two API replicas through Argo CD.

Validate the named resource-quota Argo application after an approved merge, then confirm the existing approved application rollout can reach its desired replicas. Keep the scanner incident open independently. Reducing the ceiling to 12 is a separate reviewed rollback: it would not evict existing pods, but could recreate admission failures.

Local validation: the rendered budget test reproduced 12.75 required versus 12 permitted; after increasing to 14, all 45 Helivanta chart tests, Ruff formatting/lint and strict Helm lint passed. Deployment is pending explicit approval of the infrastructure PR.
