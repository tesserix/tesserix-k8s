# Self-hosted weather activation

This chart's weather workload is disabled until its two immutable image digests
are available. Do not enable it with the old manager image. The user authorized
self-hosted Open-Meteo primary and existing Google fallback on 2026-10-12.

Prerequisites:

1. GitHub billing must allow the required CI jobs to start.
2. Publish the compatible manager maintenance branch and the `roamie-weather`
   image from `tesserix/ai-agents` after their quality and live-weather gates pass.
3. Set `weather.digest`, enable `weather.enabled` and update
   `workloads.roamie-trip-manager.digest` together. Keep the Google OpenBao mapping.
   The manager's self-hosted flag is derived from weather.enabled.
4. Confirm current active account/project/context and available schedulable
   resources before the approved production rollout. Two weather pods request a
   combined 2 CPUs, 16Gi memory and 40Gi ephemeral disk; rolling surge can add one.
   No node pool resize or external purchase was authorized or performed.
5. Review and merge through normal GitOps gates; no imperative live patching.

The service is private ClusterIP, running UID999 with a read-only root, no
service account token, bounded cache, readiness against real forecast data and
mesh source-principal authorization. Only the manager may call it. The data
cache is 8GB per pod, disposable and bounded; no PVC or backup is needed. Keep
`REMOTE_DATA_DIRECTORY` ending `/data/`; the wrong variable silently yields an
HTTP200 with null forecasts. Real-forecast readiness catches that condition.

The reusable weather image is based on the official immutable Open-Meteo 1.6.0
image plus a readiness check and its corresponding upstream source archive.
Its workflow tests Tokyo, Melbourne and New York before publishing. Local cold
requests took 6–29 seconds, warm ones 0.01–0.02 seconds; the manager bounds each
provider attempt at six seconds and uses Google on failures/limits. Google
cannot return daily forecasts in Japan and several other countries.

Post-deployment acceptance:

- Argo roamie-ai is Healthy/Synced at the reviewed revision and both weather
  replicas are ready; manager digest matches the compatible published image.
- Real manager-path requests return Open-Meteo forecasts for Japan and other
  countries, with correct attribution and explicit missing dates.
- Use an isolated QA process with simulated primary429 plus real Google (AU/US)
  to verify fallback. Do not induce an outage in the live primary service.
- Check cancellation, total deadlines, `roamie_weather_fallback` logs and absence
  of secrets in URLs/logs. Repeat authenticated trip readiness on iOS/Android.
- New weather UI wording/attribution is not included in TestFlight build5.

Rollback requires approval: restore prior manager digest and disable weather
through GitOps. This loses Japan primary coverage but preserves saved trips.

Current evidence: 49 Roamie manifest tests passed and enabled chart lint passed.
Local reusable image built and became healthy; local primary forecasts and an
isolated real-Google429 failover check succeeded. Production is still unchanged:
GitHub release run38213920022 attempt2 was blocked by billing. The user then
authorized making tesserix/ai-agents public; visibility is now public and CI
is running. This chart does not expose a public weather endpoint.
