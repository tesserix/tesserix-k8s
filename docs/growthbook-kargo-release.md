# GrowthBook pinned releases

GrowthBook uses an exact stable version plus immutable image digest. The chart
refuses floating/prerelease tags and missing or malformed SHA-256 digests. Argo
`valuesObject.image` is the production override; the inline values must not
reintroduce a competing image tag. Default values are pinned for reproducible
chart rendering, while devtest/pilot retain explicit independently pinned values.

Production upgrade orchestration belongs to `tesserix/kargo-manifests`, under
`projects/infra/{warehouses/growthbook,stages/growthbook-prod}.yaml`. It is a
dedicated lane in `kargo-infra`, so unrelated bundled platform-tool failures do
not advance or block GrowthBook's Freight. It discovers supported stable 5.2.x
patches and opens a protected-main PR updating only production image version,
digest, default image values and chart appVersion. It waits for merge and Argo
sync/health. It never pushes directly to main or upgrades MongoDB implicitly.

Automated discovery/proposal is not automatic approval of database compatibility.
Before merging each proposal:

1. Inspect vendor release notes, exact image provenance and supported Mongo/SDK
   compatibility. A minor/major upgrade requires reviewed discovery-range widening.
2. Capture current desired state, prior image reference and a recoverable database
   backup. Verify restoration independently before approving an irreversible
   schema change. An old container image cannot undo a new database format.
3. Check API/SDK health, stable on/off decisions, project/environment isolation
   and preservation of existing shared features/users/SDK connections. Helivanta
   integration needs its own acceptance; infrastructure health does not prove it.
4. Merge only after repository checks and review. Kargo/Argo record the exact
   revision and wait for health. Pause/retain the current version on failure.

There is one GrowthBook replica because its uploads PVC is ReadWriteOnce; its
existing Recreate strategy implies a short maintenance interruption when an image
changes. No replicas, resources, storage, secrets, shared flag configuration,
Mongo image or authentication settings are changed by image promotion.

Read-only inspection on 2026-11-16 found running package version 5.2.0, matching
the vendor's latest stable release, but the deployment used `latest`. This change
records a reproducible 5.2.0 registry digest; it does not claim a major-version
application upgrade or authorize clearing/reseeding shared provider data.

Validation:

```sh
uv run --with pytest --with pyyaml python -m pytest tests/test_growthbook_release_image.py tests/test_growthbook_secret_wiring.py -q
helm lint charts/thirdparty/growthbook
```

The tests render actual Helm output under default, production, pilot and devtest
values and verify invalid release references fail rendering. Kargo delivery
contracts are tested in the promotion repository. Live release evidence must
record prior/target digests, backup location, PR/commit, promotion and SDK results;
private provider data and credentials never belong in this public repository.
