# Weather and entry agent activation

Release: https://github.com/tesserix/ai-agents/pull/60
Published and resolved registry version: 1.0.6
Publish run: https://github.com/tesserix/ai-agents/actions/runs/36236352127
Tracking: https://github.com/tesserix/ai-agents/issues/61

The production baseline is explicitly in validation mode: the manager denies
customer traffic and the API trip-manager bridge is disabled. Do not claim a
customer-visible end-to-end release until the following staged rollout passes.

1. Approve rollout in project `tesseracthub-480811`, context
   `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, namespace `roamie`,
   plus the owning Zitadel bootstrap and Agent Gateway route-sync applications.
2. Merge the model-only TESSERIX machine declarations for `roamie-weather` and
   `roamie-entry-guidance`. Wait for reconciliation; obtain their generated
   subject IDs. Mint their own client credentials once and append the two logical
   agent mappings to `prod-roamie-agents-gateway-clients`. Never rotate or replace
   existing agent identities. Never put credentials in Git or command output.
3. Append the exact subjects to `roamieSeed.specialistSubjects`; preserve every
   existing subject. This remains an exact-subject and model-role allowlist.
4. Verify successful ai-agents Publish run and resolved registry `1.0.6` entries,
   then pin their immutable worker and manager image digests in `roamie-ai`.
   The manager alone receives `ROAMIE_MANAGER_WEATHER_API_KEY` from the existing
   `prod-homechef-google-weather-api-key` secret; no secret value is copied to Git.
5. Deploy in validation mode. Verify distinct model identities, signed worker
   delegation, registry discovery and source availability. Probe profile ownership,
   revision conflicts and unauthorized requests. Source and profile failures must
   remain unavailable, never be converted to invented advice.
6. After those probes, change `validationOnly` to false and both verification flags
   to true, and enable `roamie-api.tripManager.enabled`. Publish/deploy the Roamie
   API with destination coordinates and refresh the mobile build. Confirm weather
   and entry checks on a synthetic multi-destination customer trip, including dates
   beyond the forecast window, partial provider failure, cancellation and sign-out.

These steps deliberately preserve production activation gates. They require the
named production rollout approval under the workspace AGENTS.md rule. There is
no database migration, deletion, scale-to-zero or existing credential rotation.
Rollback uses the captured prior chart values and immutable image digests and
requires the corresponding rollout approval.

Visa eligibility and exact official fees are not verified by this release. The
entry specialist provides official source links and a checklist. Do not set a
verified status without a configured, tested source for the traveller's passport,
residence, trip purpose, transit route and relevant dates.
