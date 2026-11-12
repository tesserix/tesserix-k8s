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

## Notifications and sound

The chart explicitly defaults desktop and mobile push notifications to **All
messages**, message sound to **chime**, master and notification volume to **100**,
focused-conversation mute to **off**, and push to production gateway mode.
These are account defaults; user and room overrides remain
available. Do not overwrite individual preferences or subscriptions to enable
notifications, since that would undo intentional mutes.

Server settings alone do not establish delivery:

1. A workspace owner must register the workspace with Rocket.Chat Cloud, accept
   its terms, and verify the current push entitlement/quota. Do not purchase a
   plan or accept terms on an owner's behalf without explicit approval.
2. In the browser, open **User menu → Preferences → Notifications** and confirm
   **All messages** for desktop and push. If it says **Desktop Notifications are
   Disabled**, allow notifications for `https://rocketchat.tesserix.app` in the
   browser's site settings. Check the site's sound permission, tab mute, and OS
   notification/Focus settings too.
3. In **Preferences → Sound**, select the message sound and volume. Use the
   available sound preview to verify audio. Users can select no sound or lower
   the volume to mute it, and choose a sound again to unmute it. Room notification
   preferences provide per-conversation overrides.
4. On each phone, allow Rocket.Chat notifications and sounds in OS settings,
   confirm **All messages** in the app, and check room overrides, silent mode and
   Focus/Do Not Disturb. A registered push token alone does not prove delivery.
5. With a second authorized participant, test an ordinary message and a mention
   in a joined room and a direct message. Test with the browser in the background
   and the phone locked, then verify mute and unmute on each client. Do not use
   self-sent messages as evidence. Check gateway errors and quota if push fails.

### Read-only production check (2026-11-12)

- Rocket.Chat 8.9.0 and all three MongoDB pods were running; Argo CD reported
  `Synced` at `4e876121326b1d66242281fca1e614fd1429c380`.
- Effective desktop and push defaults were `all`, message sound `chime`, volume
  `100`, and push enabled with the production gateway.
- `Cloud_Workspace_Id` and `Register_Server` were unset. Two iOS device records
  existed in `_raix_push_app_tokens`; no Android record was present.
- The signed-in Chrome account's notification screen showed **All messages**
  for desktop and push, but **Desktop Notifications are Disabled**.
- Chrome site notifications were subsequently enabled. The signed-in user's
  sound preferences were saved with focused-conversation mute off; the UI showed
  Chime and master/notification volume 100. A desktop test was triggered, but
  actual OS delivery/audio was not independently observed.
- Mahesh was added through the supported UI to the 14 missing channels. A
  subsequent read-only check confirmed membership in all 18 public/private
  channels. Both active admitted humans now belong to all existing channels.
- Global focused-conversation mute and scheduled membership defaults are prepared
  in this change, pending credential provisioning and an approved GitOps rollout.
  Phone delivery and mute/unmute acceptance remain pending.
- The owner then explicitly approved Cloud registration, the owner email
  `samyak.rout@gmail.com`, and acceptance of the Rocket.Chat Terms/Privacy Policy.
  Email verification completed. The workspace displayed **Workspace registered**
  and mobile push availability; read-only settings confirmed `Register_Server`
  and `Cloud_Workspace_Id` populated. Registration activated a Starter entitlement
  automatically; no paid plan was purchased. Its actual push quota and delivery
  still need verification.

## Default channel membership

The owner explicitly requires every admitted human account to belong to every
active public and private channel, existing or new. This includes existing
private-channel history. It does not authorize public registration, a broader
Zitadel allowlist, bot access to other products, or access to direct messages.

`rocketchat-membership` runs every minute when `membership.enabled=true`. It uses
paginated supported APIs to list active human users and public/private channels,
then idempotent invitation APIs to ensure their subscriptions. Eligible accounts
have type `user` and the `user` role, as granted by the existing SSO configuration;
bot/app/guest/anonymous identities and deactivated accounts are excluded. Removing
a human from an active channel is repaired on a later run; personal mute and sound
preferences are not changed. Archived channels are left untouched.

The job fails on authentication/authorization/API errors and logs counts or
sanitized errors, never messages or credentials. A failed run is retried by the
next scheduled run; Kubernetes does not immediately retry a permanent API error.
There is no membership deletion or account reactivation. Removing `user` from an
account or deactivating it stops future additions; access revocation still needs
normal Rocket.Chat session/account offboarding.

Before enabling this in production:

1. Obtain approval to provision a dedicated administrator automation credential
   and publish/deploy this GitOps change. Community 8.9.0 does not offer custom
   roles; listing all private rooms and inviting humans requires administrator
   authority. Use a dedicated, named Personal Access Token on an existing admitted
   administrator account, with normal two-factor checks retained. This avoids
   adding an extra privileged login identity. Do not reuse a product bot
   credential or export browser cookies. Revoke the named token on retirement.
2. Using the supported administrator API/token workflow and a short-lived
   OpenBao writer bound to `seed-rocketchat-membership-production`, create the
   exact paths below with CAS=0. Refuse an existing differing value. Each stores
   only a `value` property. Never print the token or commit credential material.
   The dedicated namespace-bound ESO reader can read only these two paths.
   - `rocketchat/prod/app/rocketchat-membership-auth-token`
   - `rocketchat/prod/app/rocketchat-membership-user-id`
3. Reconcile the OpenBao policies/roles first, then Rocket.Chat. Confirm the
   `rocketchat-membership` ExternalSecret is Ready without displaying its data.
   The CronJob uses the existing pinned Rocket.Chat image, no Kubernetes API
   token, and network access limited to Rocket.Chat plus namespace DNS. Its
   request is 10m CPU/64Mi memory only while running, with a 128Mi memory cap.
4. Verify the first Job completes and its counts cover every eligible human and
   active channel. With a newly approved human and a new public/private channel,
   verify membership on the next completed run. Do not claim the automation is
   active based solely on a rendered Helm chart or local tests.
5. Monitor failed `rocketchat-membership` Jobs and delayed runs alongside the
   existing Kubernetes job monitoring. The production `monitoring` namespace
   currently has `KubeJobFailed` and `KubeJobNotCompleted` alert rules. To stop additions, deploy
   `membership.enabled=false`; existing memberships are preserved. Credential
   rotation requires separate approval: replace the API token, update the same
   OpenBao path with CAS, wait for ESO refresh, verify a successful run, then
   revoke the old token. Revoke access and remove membership explicitly when
   offboarding; the job does not delete data or revoke access.

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
