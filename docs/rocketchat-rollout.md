# Rocket.Chat rollout

Prepared for `tesseracthub-480811`, context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, namespace `rocketchat`,
and https://rocketchat.tesserix.app. Architecture and limits: [ADR](adr/0020-rocketchat.md).

## GitOps rollout order

1. Review and publish only the Rocket.Chat branch changes. The original working
   checkout has unrelated edits and must not be staged wholesale.
2. Reconcile OpenBao's new exact-path policy and namespace-bound reader role.
3. Sync the new `rocketchat` application. Its project claim must reach `Ready=True`.
   Pending pods/ExternalSecrets are expected until credential bootstrap finishes.
   The application deliberately has no automated sync or prune policy.
4. Obtain a short-lived non-root OpenBao writer with exact create/read/update
   access to all six paths below, and an authorized Zitadel PAT. Supply them only
   as `BAO_TOKEN` and `ZITADEL_PAT` in the process environment. Use a local port
   forward for `BAO_ADDR` (default `http://127.0.0.1:18200`). Never paste either
   credential into a command argument, Git, chat, or logs.
5. Run `python3 scripts/identity/bootstrap-rocketchat.py`. It verifies project
   checks and exactly two verified users/grants before creating the confidential
   `rocketchat-web` client. It creates missing secrets with CAS=0, checks readback,
   and revokes its temporary OpenBao token. It refuses implicit rotation. If
   identity creation succeeds but storage fails, stop and explicitly recover
   that application; do not create duplicate clients or rotate without approval.
6. Wait for ESO readiness, all three database pods, the elected primary, and the
   app readiness probe. Check the live image digest, authenticated DB connection,
   host-scoped gateway allow rule, HTTP API and WebSocket connection.

Paths (all hold a single `value` property):

- `rocketchat/prod/app/rocketchat-mongodb-root-password`
- `rocketchat/prod/app/rocketchat-mongodb-password`
- `rocketchat/prod/app/rocketchat-mongodb-keyfile`
- `rocketchat/prod/app/rocketchat-mongodb-uri`
- `rocketchat/prod/app/rocketchat-zitadel-client-id`
- `rocketchat/prod/app/rocketchat-zitadel-client-secret`

Zitadel owns authentication and MFA. Rocket.Chat local two-factor challenges and
automatic email-OTP enrollment are disabled; local password login and public
registration remain disabled. After changing these settings, dismiss any old OTP
dialog, refresh the page, and start a new **Sign in with Tesserix** attempt.

## Acceptance before replacing Slack

- Sign in as both approved people, verify workspace administration and messaging.
- Try a third Zitadel account and confirm denial before Rocket.Chat provisioning.
- Confirm public registration and password recovery fail, not just that UI links
  are hidden. Inspect existing accounts: no extra human accounts or local passwords.
- Install the official mobile app; enter `https://rocketchat.tesserix.app` and choose
  **Sign in with Tesserix**. Test browser return to the app and session renewal.
- Register the workspace with Rocket.Chat and have an owner accept the cloud
  service terms. Check the account's current push quota/plan. Lock the phone and
  send a mention/direct message; verify a delivered notification on each platform.
- Configure encrypted off-cluster MongoDB and upload backups with least-privilege
  credentials, retention and alerts. Perform an isolated restore and record RPO/RTO.
  This initial chart does not yet provide backups and must not become the sole
  record of support conversations before that gate passes.
- Create private operations/support channels. Inventory Slack notification senders,
  then migrate one at a time using narrowly scoped bot/webhook credentials in
  OpenBao. Verify each event arrives once and has a useful link. Keep Slack active
  until the full sender inventory, retry behavior and delivery tests pass.

For offboarding, remove the Zitadel grant AND deactivate the Rocket.Chat account
and invalidate its sessions. For recovery, preserve PVCs and restore backups;
do not assume a previous image can read a migrated database schema.

## iOS login TLS compatibility (2026-10-26)

Rocket.Chat iOS 4.77.2 uses a native WebSocket connection that failed against
Cloudflare's TLS 1.3 minimum, even though HTTPS REST requests and Zitadel OAuth
succeeded. The app returned to the sign-in screen. The native error was
`OSStatus -9836`; a forced TLS 1.2 request failed with `protocol version`.

Cloudflare Advanced Certificate Manager ($10/month, approved) enables the exact
hostname exception. The zone `tesserix.app` retains minimum TLS 1.3. Only
`rocketchat.tesserix.app` has a minimum TLS 1.2 override; TLS 1.3 remains enabled.
No Kubernetes workload, disk, origin certificate, or Zitadel TLS change is needed.

To reproduce this configuration:

1. Enable Advanced Certificate Manager for the zone with billing approval.
2. Use a temporary API token scoped to this zone with
   `Zone / SSL and Certificates / Edit`. Do not broaden the shared DNS token.
3. Record `GET /zones/{zone_id}/hostnames/settings/min_tls_version` before editing.
4. Apply `PUT /zones/{zone_id}/hostnames/settings/min_tls_version/rocketchat.tesserix.app`
   with JSON `{"value":"1.2"}`. Never lower the zone-wide minimum.
5. Read back the hostname settings and confirm the zone minimum is still 1.3.
6. Verify `curl --tlsv1.2 --tls-max 1.2 https://rocketchat.tesserix.app/api/info`
   succeeds while the same TLS restriction against `https://auth.tesserix.app`
   still fails. Test the native app, since generic clients may negotiate TLS 1.3
   and miss this compatibility issue.
7. Revoke the temporary Cloudflare token and remove local credential files.

The native iPhone 17 Pro Max simulator WebSocket opened successfully after the
change (normal close code 1000), and the owner confirmed mobile login worked.
A transient Cloudflare 520 on the identity hostname occurred during retry;
OIDC discovery returned HTTP 200 afterward. A 520 requires origin/Cloudflare
investigation, not another reduction of the zone TLS policy.

Temporary QA access must be removed after testing: remove the project member via
GitOps, deactivate its Rocket.Chat account and invalidate sessions, and disable
only the temporary TESSERIX identity. Preserve the separate CivicLens QA identity.
