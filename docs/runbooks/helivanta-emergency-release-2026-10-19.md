# EmergencyConnect release evidence — 19 October 2026

The protected staff release is deployed. The full citizen-to-hospital programme
[#1220](https://github.com/tesserix/helivanta/issues/1220) remains open. No real
patient booking, staff qualification or hospital approval was fabricated.

## Deployed source and artifacts

Application: [helivanta#1246](https://github.com/tesserix/helivanta/pull/1246),
commit `9285628e61030794310efb7382b61f94db4aa916`.
Infrastructure prerequisites/activation: [#1460](https://github.com/tesserix/tesserix-k8s/pull/1460),
[#1461](https://github.com/tesserix/tesserix-k8s/pull/1461),
[#1463](https://github.com/tesserix/tesserix-k8s/pull/1463),
[#1462](https://github.com/tesserix/tesserix-k8s/pull/1462).
Activation source: `a7b21da84908b69237cddb6ac1d17f18cefa7d24`.

| Artifact | Running digest |
| --- | --- |
| API and Go workers | `sha256:75983983f5632305a7ad119043dfe39aa0c3c9a60dcbe72f285f22a5acf566f0` |
| Production Next web | `sha256:3a1c1c00bc6579f63152dacf37ce1ebf5d5b82f56326e7ccb148ab2c893f674b` |

These digests were verified against running container image IDs and their GCP
mirror references under `ghcr-remote/tesserix/helivanta/`. The main image pipeline
completed vulnerability scans, SBOM generation, keyless signing and deploy-branch
promotion. Cloud Build fallback was prepared but not used. This evidence does
not claim that cluster admission enforces image signatures.

All three repositories remain public: Helivanta, tesserix-k8s and
 tesserix-operators. The operators module remains on Go 1.27.2.

## Tests and observed production state

- Required application PR checks and the subsequent main-branch CI passed:
  [PR CI](https://github.com/tesserix/helivanta/actions/runs/39133609514),
  [main CI](https://github.com/tesserix/helivanta/actions/runs/39134987862),
  [images](https://github.com/tesserix/helivanta/actions/runs/39134987464).
- Web suites: 563 shell, 315 API-client and 95 shared-UI tests. General end-to-end
  suites and seven separate emergency browser journeys passed. The hospital
  journey used the production-named non-superuser owner, disposable real
  Postgres/OpenBao/NATS and a 390px viewport.
- Full backend race/coverage gate passed. The independent authorization/privacy
  architecture suite passed with race detection. All gated runtime packages
  exceeded the existing 70% floor; emergency coverage was 75.2%.
- A tagged 100,000-row synthetic history test confirmed an indexed crew lookup
  under application-role forced RLS (0.42ms observed fixture execution; not a
  production latency guarantee).
- Infrastructure activation CI passed 928 tests and 53 subtests, with the four
  existing quarantined tests unchanged. Real OpenBao ACL/CAS initialization tests
  passed independently, including concurrent initialization and deleted-version
  refusal. Staged and branch Gitleaks scans passed.
- Production migrations `0001_emergency` through `0007_emergency` are recorded.
  The actual relation owner is `helivanta`; zero policies retain the test owner
  assumption and no privileged `hms_owner` alias was created.
- API, web, emergency worker, document worker and evidence worker were each 2/2;
  ClamAV was 1/1. Their Argo applications were healthy and synced. Emergency
  workers had no restarts and two fresh workflow plus two activity pollers on
  `emergency-dispatch-v1` in `helivanta-documents-prod`.
- The emergency runtime login is NOINHERIT/NOSUPERUSER/NOBYPASSRLS, cannot create
  databases/roles or replicate, has zero role memberships and a connection limit
  of 16. The API is not a member of that role. No credential value was read,
  printed or rotated during verification.
- The namespace-bound create-only OpenBao initializer completed. Its token can
  create one exact path and read version metadata; it cannot read/update/delete
  the password or access other paths. ESO reported the credential synchronized.
- CPU limits measured 11,450m/12 and memory 14,720Mi/16Gi. Requests measured
  2,100m/4 CPU and 5Gi/6Gi memory. This snapshot leaves 550m CPU for the 500m
  migration hook; concurrent surges and load growth need separate capacity review.
- Signed-in browser checks verified YES Hospital operating bases, own crew
  assignments, hospital receiving and the existing pharmacy stock register.
  The tenant has no approved emergency operating base; no clinical data was added.
- Without cookies, the three protected API collections returned 401 through an
  authorized local origin forward; the documented public `/ambulance` page
  returned 200. Public CLI probes returned 403 through the edge, so those were
  not misreported as application-layer auth tests.

The initial 64Mi seed proxy was OOMKilled; a reviewed replacement with 256Mi
completed successfully. The failed attempt is preserved with explicit obsolete
resource comparison/health annotations; its specification was captured locally
before replacement. No diagnostic object was deleted to hide that failure.

## Activation and remaining work

The running API explicitly has `EMERGENCY_WORKFLOWS_ENABLED=true` and
`EMERGENCY_DISPATCH_ENABLED=false`. Existing-trip orchestration is on; new
reservations remain suspended. Synthetic software verification supplies no
clinical authority. A real dispatch/clinical lead and approved hospital policies
are required before a clinical pilot.

Citizen online booking/status/cancellation, native GPS/driver journeys and device
acceptance, canonical workforce qualification linkage and the remaining programme
acceptance work are still outstanding. Workflow opaque IDs remain sensitive
scoped metadata; structural field classification is not legal de-identification.
No SOC 2 attestation, HIPAA compliance certification or operational emergency
service integration is established by this release.

The image audit found upstream Istio/CNPG references beyond the application
images. The [registry cutover plan](helivanta-registry-cutover.md) prepares their
GCP mirror migration; it requires separate maintenance approval for database
switchover and the single-instance scanner restart. Historical terminal Job
records retain their original image references for audit accuracy.
