# mark8ly support chat and Rocket.Chat

The mark8ly web admin **Chat with Tesserix** widget and mobile platform-support
bridge continue to use shared Otto. Only newly created, authenticated conversations
stamped `product_id=mark8ly` under `platform/default` are eligible. Customer chats
with a merchant's own staff and other products are excluded. No historical cases
are automatically backfilled.

## Operator experience

1. Sign in at https://rocketchat.tesserix.app using the existing approved Zitadel
   account and open `support-mark8ly`.
2. Each case gets one root message showing customer identity, merchant, case ID,
   reason and issue. DOB/session tokens are never included. Customer messages
   appear as thread replies; open the thread before responding.
3. A plain-text reply from an allowlisted staff ID returns to the customer's
   existing mark8ly chat. The first reply claims an unassigned case. The existing
   assignee restriction applies to subsequent replies. Top-level channel messages,
   bot messages, attachments, edits, and other authors do not reach customers.
4. Otto's existing content policy applies. A rejected reply gets a thread notice;
   use the support inbox to resolve assignment or reopen a closed case. The
   bridge does not implement slash commands or attachment delivery.
5. Closed cases receive a closure notice; no further replies are delivered until
   the case is reopened in the existing support inbox.

Staff are authorized by immutable Rocket.Chat user IDs, not editable display
names. Samyak's ID is `di5AZaipoTQcRjMu2`. Mahesh has not yet created a Rocket.Chat
user by signing in; after his first approved Zitadel login, resolve that account's
ID and add it to `rocketchat.staffIDs` through GitOps. Do not guess an ID, broaden
to all channel members, or permit a bot to administer users.

## Provisioning and rollout

1. Follow [the product channel guide](rocketchat-product-onboarding.md) to create
   the channel and invite the approved humans. Reuse existing `support-mark8ly`.
2. Create a dedicated `mark8ly-support-bot`, only the built-in `bot` role, no
   default-channel joining. Subscribe it only to this channel. Community edition
   does not support custom roles. Verify its effective permissions before use.
3. Store its PAT directly in OpenBao KV v2 at
   `kv/support-platform/app/support-platform-mark8ly-rocketchat`, properties
   `token`, `user_id`, `room_id`. Shared Otto owns this credential, so its reader
   is namespace-bound to `support-platform`. Never print the PAT or use a browser
   environment variable. Do not reuse the onboarding bot credential.
4. GitOps grants that exact OpenBao path to
   `read-support-platform-support-platform-production`. The ExternalSecret
   `support-platform/mark8ly-rocketchat-support` projects
   `ROCKETCHAT_SUPPORT_AUTH_TOKEN`, `ROCKETCHAT_SUPPORT_USER_ID`, and
   `ROCKETCHAT_SUPPORT_ROOM_ID`. Verify it is Ready without displaying data.
5. Merge and deploy the mark8ly provenance change and shared Otto bridge through
   their existing image delivery pipelines. Keep `rocketchat.enabled=false`
   until the compatible Otto binary and secret are ready. Confirm the web and
   mobile proxies point to shared Otto, not the older product-local service.
6. Enable `rocketchat.enabled` in the shared Otto Helm chart through GitOps.
   Check every pod is ready and uses the expected image/secret refs.
7. Create a clearly labelled synthetic case through the real authenticated Otto
   endpoint. Verify root and customer line in Rocket.Chat; reply from an approved
   human account and verify the same reply appears in Otto's customer transcript.
   Replay both directions and check one message and one counter increment.
8. Verify a different product marker, another room, an unauthorized sender,
   closed case, edited message, and blocked text cannot deliver a customer reply.
   Record synthetic verification separately from an actual customer interaction.

Bot ID: `dWynpJaaDTL5XNEoH`; room ID: `6adeda0adfe0bc336c6d4be9`.
The one-time provisioning sessions, temporary PAT grant and OpenBao writer were
removed. Read of the onboarding room and user administration is denied.

## Reliability and recovery

The committed Otto conversation/message documents are the durable source.
Outgoing root IDs are `mark8ly-support-<case-id>`; lines use
`mark8ly-support-msg-<message-id>`. The worker confirms room, author, text and
thread before treating an existing message as delivered. A remote success
followed by a crash is safe to retry. Successfully delivered documents carry
`rocketchat_delivered=true`.

Incoming replies use `rocketchat-<remote-message-id>` under Mongo's unique `_id`.
A transaction inserts the message, updates case status/counters/assignee and
appends an attributed audit event. Duplicate processing has no second counter
increment. Customer clients can reload their transcript if a live broadcast is
missed. The worker uses HTTPS with bounded bodies, deadlines and no redirects.

Case polling is bounded to 20 due cases per pass; outbound pages contain 100
messages, inbound pages 100 replies (10,000 reply safety cap). Normal polling is
5 seconds; closed cases are revisited hourly to drain final output. Failures
back off with jitter and stop after 12 attempts with `rocketchat_state=dead`.
Monitor that field and `rocketchat_next` age with aggregate counts, not payload
logs. The source conversation remains usable during a Rocket.Chat outage.

After resolving an outage, requeue only reviewed mark8ly case IDs by resetting
`rocketchat_attempts=0`, `rocketchat_state=active`, and `rocketchat_next` to now.
Keep message IDs, delivery markers, and original content. Never mass-replay
historical conversations. For rollback, disable the bridge through GitOps before
restoring an older image; retain case/message records and secret for recovery.
Credential rotation/revocation and deleting records require separate approval.

## Future product operator

Extend the proposed product resource with a support bridge block containing the
product identifier, namespace, exact OpenBao reference, channel ID, bot ID,
immutable staff IDs and bridge version. Reconcile channel → bot → secret → ESO
Ready → compatible binary → enablement → synthetic round-trip verification.
Expose states for `AwaitingStaffFirstLogin`, `CredentialReady`, `BridgeReady`,
`VerificationFailed`, and `Ready`. Do not mark a channel as integrated merely
because it exists. Preserve human memberships and unrelated bot permissions.

The controller must use a narrowly privileged Rocket.Chat provisioning API and
namespace-scoped OpenBao writer; it must never receive MongoDB exec, shared
bootstrap, human admin session, or cluster-admin access. The temporary bootstrap
technique used manually is not an operator permission model. Do not temporarily
grant PAT creation to the shared bot role in automated multi-product operation;
use an audited credential provisioning boundary. Exact grants, GitOps ownership,
rollback and one-time secret delivery belong in the operator's reviewed design.

No operator is installed by this change. No new disks or services are created;
the existing standard storage remains unchanged.
