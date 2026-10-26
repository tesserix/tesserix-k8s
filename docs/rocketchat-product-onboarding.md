# Adding a product to Tesserix Rocket.Chat

This runbook describes the supported onboarding process and the contract for a
future operator. It does not claim that an operator exists today. The first
implementation is mark8ly; Helivanta and fe3dr already have channels but their
application integrations are not enabled by this change. Support channels remain
unconnected until their event requirements are agreed.

Workspace: https://rocketchat.tesserix.app. Registration data lives in
[`config/rocketchat/products.yaml`](../config/rocketchat/products.yaml); it is a
reviewable inventory, not an installed Kubernetes CRD. Never put credential
values in that file. Product-specific rollout evidence lives in
[mark8ly-rocketchat-onboarding.md](mark8ly-rocketchat-onboarding.md).

## 1. Define the product event before creating credentials

Record the product slug, environment, owning repository/service, namespace,
channel name, event semantics, data fields, and operational owner.

For mark8ly the trigger is the successful initial **tenant and first store**
transaction. It is not an ordinary login, invitation acceptance, abandoned
onboarding, or creation of another store under an existing tenant. A different
product might use a first verified user record instead. Do not assume these
are the same event or deduplicate solely on email: one person can own multiple
businesses and email can change.

Use `onboarding-<product>` for signup notifications and `support-<product>` for
support. Production and development must have different destinations and
credentials; use an explicit environment suffix for non-production channels.
Product aliases do not create extra channels: HomeChef is fe3dr and HMS/Medicare
is Helivanta. Reuse an existing channel instead of creating a numbered duplicate.

Choose the allowed fields explicitly. mark8ly uses owner name/email, business
name, tenant/store IDs, store slug, completion timestamp, country, currency,
timezone, classification, and generated admin/storefront URLs. Exclude passwords,
tokens, cookies, drafts, tax identifiers, payment data and arbitrary request
objects. These messages and their outbox snapshots contain customer contact
information; apply the workspace/database/backup access and retention policies.

## 2. Create or find the channel

### Browser procedure

1. Open the workspace and sign in through the existing Zitadel button. Human
   access remains restricted to the approved users; creating a channel must not
   widen the Zitadel allowlist or enable local/public registration.
2. Search the directory for the exact channel name. If it exists, open it and
   verify its purpose and visibility. Do not create a duplicate.
3. Click **Create new → Channel**.
4. Enter `onboarding-<product>` and a topic such as
   `First-time signup notifications for <Product>. Integration pending.`
5. The dialog defaults to **Private**. For the current two-user workspace,
   turn this off to make the channel discoverable to admitted workspace users.
   “Anyone can access” here means admitted users while anonymous access remains
   disabled. If the workspace later admits more people, review customer-data
   access and use a private channel with explicit membership where appropriate.
6. Create the channel and verify it appears once in the sidebar/directory.
7. Add the product service identity only after its permissions are restricted.
   Add the humans who want notifications as channel members. Their personal
   notification preferences and mobile push/device setup are separate steps.
8. Replace “Integration pending” in the topic after delivery is verified.

For a private channel the API family is `groups.*`; for a workspace channel it
is `channels.*`. Do not silently change the visibility of an existing channel.

### API procedure for automation

Use an authenticated administrator/provisioning client, not the product bot.
Use the HTTPS workspace URL, or an authenticated loopback Kubernetes
port-forward for administration when edge rules reject machine clients:

```sh
kubectl --kubeconfig ~/.kube/gke-prod -n rocketchat \
  port-forward svc/rocketchat 18300:3000
```

A loopback tunnel is local-only. Do not bind it to `0.0.0.0`. Do not copy browser
cookies or print credentials to obtain an API session. Runtime application
traffic must use HTTPS; the port-forward is not the application endpoint.

| Operation | REST API | Relevant input/result |
|---|---|---|
| Find public channel | `GET /api/v1/channels.info?roomName=onboarding-<product>` | Save `channel._id` |
| Create public channel if absent | `POST /api/v1/channels.create` | `{"name":"onboarding-<product>","members":[]}` |
| Set topic | `POST /api/v1/channels.setTopic` | `roomId`, `topic` |
| Invite product bot | `POST /api/v1/channels.invite` | `roomId`, `userId` |
| Verify membership | `GET /api/v1/channels.members?roomId=<id>` | Paginate and compare IDs |

Only an explicit not-found response permits creation. Authentication, rate-limit,
network and server errors are not “missing”. On a concurrent create conflict,
refetch and validate the existing resource; never switch to a new name. Persist
the immutable room ID, because application delivery uses it rather than a name.

## 3. Provision a restricted product service identity

Rocket.Chat 8.9.0 Community does not support custom roles without a paid license.
Do not insert custom roles directly into the database or enable paid features by
editing state. Use the supported built-in `bot` role and restrict it through the
Permissions API. The desired steady-state permission set is only
`view-joined-room`; sending a normal message in an accessible joined room does
not require a separate `send-message` permission in this version.

This role is workspace-wide. Before changing it, inventory existing bot users
and review the impact. At first provisioning, only the built-in `rocket.cat`
existed. Future product bots share this restricted role and must never receive
`user`, `admin`, `app` or a second role that restores broad privileges.

Remove the stock bot grants for public/unjoined-room access, room creation,
impersonation, API rate-limit bypass, high-rate sending and edit/delete time-limit
bypass. Keep `view-joined-room`. Avoid broad replacement of permission documents:
modify only the `bot` membership of each permission, preserving human roles.

| Operation | REST API | Purpose |
|---|---|---|
| Inspect permissions | `GET /api/v1/permissions.listAll` | Entries are in `update`, not `permissions` |
| Add/remove bot grant | `POST /api/v1/permissions.addRole` or `.removeRole` | `permissionId`, `role: "bot"` |
| Look up identity | `GET /api/v1/users.info?username=<product>-onboarding-bot` | Verify existing roles and intended ownership |
| Create identity | `POST /api/v1/users.create` | Name, unique username/email, random password, `roles:["bot"]`, `joinDefaultChannels:false`, `sendWelcomeEmail:false` |
| Create temporary session | `POST /api/v1/login` | Generated service username/password, kept only in memory |
| Generate durable PAT | `POST /api/v1/users.generatePersonalAccessToken` | Under bot session: `tokenName`, `bypassTwoFactor:false` |
| Close temporary session | `POST /api/v1/logout` | Revoke only that bootstrap session |

The PAT endpoint requires `create-personal-access-tokens`. Grant it to the bot
role only during provisioning and remove it in `finally`, including failure
paths. Recheck that the role contains only `view-joined-room` afterwards. Existing
credentials must be reused; a missing secret with an existing bot is a recovery
condition, not permission to rotate a token or create another account.

The product bot belongs only to its onboarding room. It must not auto-join
`general`, support rooms or other products. Verify actual API denial for an
unjoined room and user administration. Do not rely only on the role label.

### Administrator bootstrap boundary

Prefer an administrator-issued short-lived API session supplied through an
approved secret mechanism. The initial mark8ly setup had no automation token:
cluster-authorized execution temporarily added a single hashed Meteor session to
the already-approved administrator, then removed exactly that session in
`finally`. It did not read, copy or invalidate existing human sessions. This was
a one-time bootstrap operation, not the design for an operator.

Do not give a future operator MongoDB or `pods/exec` privileges to repeat this.
Provision its control-plane identity once, scope its API capabilities, store its
credential separately from product credentials, audit privileged actions and
rotate through an explicit approved operation. Database bootstrap requires a
specific authorized administrative procedure and verification of cleanup.

## 4. Write the credential to OpenBao

Use the product's established environment path, for example:

- production: `kv/mark8ly/app/mark8ly-rocketchat-onboarding`;
- UAT: a separate `kv/mark8ly-uat/app/...` path and separate bot/channel;
- never a new GCP Secret Manager application secret.

The KV v2 data is an object with `token`, `user_id`, and `room_id`. Do not make
`token` a Helm value, environment dump, GitHub output, URL query parameter or log
field. Use create-only CAS (`options.cas=0`) on the first write. On retry, read
and verify the existing credential instead of overwriting it. A mismatched value
requires explicit rotation/recovery handling.

Routine human writes use the authorized Tesserix secret console. For the approved
initial automated provisioning, a ten-minute Kubernetes-auth writer was scoped
to exactly the destination path with create/read access. The temporary role,
policy and both tokens were removed/revoked at completion. Never reuse broad
bootstrap/root privileges as a runtime writer. See
[OpenBao break-glass](runbooks/openbao-break-glass.md) for its authorization model;
its older inventory counts are historical, not the current source of truth.

In GitOps:

1. Add exact-path `read` access to the product namespace's existing reader policy.
2. Add an ExternalSecret using the namespace-bound SecretStore.
3. Map the object fields to server-only environment keys. For mark8ly:
   `ROCKETCHAT_AUTH_TOKEN`, `ROCKETCHAT_USER_ID`,
   `ROCKETCHAT_ONBOARDING_ROOM_ID`.
4. Merge/sync policy and ExternalSecret before enabling the workload.
5. Verify ExternalSecret `Ready=True`, target Secret existence/key names and
   in-memory value equality without printing values.
6. Ensure another product namespace's reader cannot read this path.

## 5. Integrate the product application

Put the notification intent in the same database transaction as the successful
business state change. Use the product's existing outbox when available. Never
send chat HTTP inside that transaction, from frontend code, or after commit
without a durable event: those approaches either slow signup or lose events.

The mark8ly implementation is in `services/platform-api/internal/onboarding/`;
`rocketchat.go` formats an explicit allowlisted event and returns an outbox
handler. Configuration is server-only and the feature defaults off until its
credential is ready.

Use the durable business identity in a stable message ID, for example
`<product>-onboarding-<tenant-uuid>`. Include the environment if environments
share a workspace. Persist the completion time in the event; do not use the
current time on each retry. Format user text safely, neutralize standalone
mentions, bound field lengths, and allowlist generated link hosts.

Delivery algorithm:

1. `GET /api/v1/chat.getMessage?msgId=<stable-id>`.
2. If found, verify room, author and content before acknowledging delivery.
3. If explicitly missing, `POST /api/v1/chat.sendMessage` with
   `{"message":{"_id":"...","rid":"...","msg":"..."},"previewUrls":[]}`.
4. Require success and matching returned message/room IDs.
5. On timeout or ambiguous failure, retain the event for retry. On retry the
   stable ID lets the worker recognize a message already accepted by the server.
6. Use finite deadlines, bounded retries/backoff and a visible dead-letter state.
   Reject redirects so authentication headers cannot move to another origin.

Rocket.Chat's duplicate message ID prevents a second stored message when a
response is lost. The database-to-chat operation is still at-least-once delivery,
not a cross-system transaction. Verify that retry transitions reset the outbox
row to a claimable state; mark8ly's existing retry bug was fixed as part of this
integration. Do not silently treat a conflicting message as success.

## 6. Release and verify

1. Test atomic enqueue, rollback, repeat completion, safe formatting, credential
   redaction, retry/replay, timeouts, redirects and authorization boundaries.
2. Build the image from merged code and record its immutable revision/digest.
   A missing pinned base image is a build failure to repair, not a reason to
   bypass CI. Keep the replacement pinned to a verified registry digest.
3. Confirm bot permissions, OpenBao secret and ExternalSecret readiness.
4. Deploy a compatible binary everywhere before enabling event production.
   Disabled replicas must recognize the new event kind and retry it, so the
   rolling enablement cannot dead-letter events as unknown kinds. For mark8ly,
   Kargo owns live image parameters: promote the verified service freight, wait
   for healthy replicas, then merge the notification feature flag. The
   mark8ly Argo app auto-syncs, so this merge is the production rollout.
5. Verify Argo desired/live revision agreement, healthy pods and HTTP readiness.
6. Queue a clearly labelled synthetic event with an `.invalid` email and synthetic
   IDs through the real outbox; do not create a fake paying customer. Verify one
   nicely formatted channel message and a delivered event.
7. Replay that same synthetic event without changing its ID/payload. Confirm one
   message remains and the outbox returns to delivered.
8. Confirm no new support integration, public registration or extra human access
   was enabled. Test cross-room read denial and prohibited API operations.
9. Record synthetic verification separately from the next actual customer
   signup. A successful synthetic event does not prove a real customer signed up.
10. Set the channel topic to describe the live notification flow. Verify mobile
    push separately on each user's device; do not infer it from a browser message.

Do not delete verification messages or customer/outbox data as routine cleanup.
Close local port-forwards and revoke temporary administrative/writer sessions.

## 7. Operate, recover and add the next product

Monitor pending age, failure/dead counts, attempts and delivery latency by
product/environment/event kind. Logs contain event IDs and sanitized errors,
not message bodies or tokens. Treat any dead event as requiring investigation;
use an aggregate age/count alarm and an operational owner before relying on chat
as the sole notification path.

After an outage, replay only reviewed event IDs, keeping the original stable ID
and payload. A token rotation updates OpenBao, waits for ESO refresh, restarts
consumers that read secrets only at startup, verifies delivery, then revokes the
old token. It is a separate approved action; never rotate on reconciliation.

Before a rollback, capture pending/in-flight/dead IDs and drain when possible.
Old application binaries do not know the new event kind and can dead-letter it.
Preserve events and secrets for recovery. Roll back through GitOps, never by
changing a live Deployment that Argo will overwrite.

For fe3dr or Helivanta, repeat the business-event mapping and namespace credential
steps, reuse the existing channel, and create a different bot/PAT. Share the
message-format requirements and operational contract, not a cross-product token.

## 8. Future operator design

The operator should automate provisioning and verification, while each product
still owns the transaction that decides onboarding is complete. A Kubernetes
controller cannot reliably infer business signup completion from pod activity or
Zitadel login events.

Planning assumptions, not measured traffic: 1,000 signups/day/product is 0.012
average events/sec, roughly 0.12/sec at 10× peak. At 4 KiB/event, snapshots alone
are about 1.5 GB/year/product or 4.5 GB over three years, before indexes/backups.
Each initial delivery needs one read and one write. Target 99% delivered within
60 seconds while chat is healthy, with no chat latency added to signup. Measure
actual volumes before setting retention, worker concurrency or alerts.

A future `ProductChatIntegration` resource should contain references, not tokens:

```yaml
apiVersion: notifications.tesserix.app/v1alpha1 # proposed, not installed
kind: ProductChatIntegration
metadata:
  name: mark8ly-onboarding
  namespace: mark8ly
spec:
  product: mark8ly
  environment: production
  channel:
    name: onboarding-mark8ly
    visibility: workspace
    adoptExisting: true
  credentialRef:
    openbaoPath: mark8ly/app/mark8ly-rocketchat-onboarding
    secretStore: openbao-mark8ly-production
  event:
    kind: rocketchat.onboarding_completed
    identity: tenant-id
  delivery:
    desiredState: enabled
  deletionPolicy: Retain
```

Suggested reconciliation states:
`Validated → ChannelReady → IdentityReady → CredentialReady → SecretReady →
WorkloadReady → DeliveryVerified → Ready`. Publish `observedGeneration`, room ID,
service-user ID, credential version (never value), last verified application
revision, and conditions with sanitized reasons. Distinguish `Provisioned` from
`DeliveryVerified`; a created Secret alone is not successful integration.

Use a single owner/lease per product/environment to avoid concurrent credential
creation. Reads and CAS writes make reconciliation idempotent. Adopt an existing
channel only after validating visibility/name/ownership; ambiguous or mismatched
resources become a condition requiring review. Never rename, delete, archive,
rotate, widen access, add human users or replay old customers automatically.

Only platform administrators should register integrations. Derive allowed channel
prefixes, namespace, SecretStore and OpenBao paths from the product/environment
registration; reject cross-product references or arbitrary workspace URLs even
when a resource exists. Tenant application service accounts must not be able to
create or edit integration resources. Validate this boundary before obtaining a
writer token, so a malicious resource cannot turn the controller into a
cross-namespace credential reader.

The provisioner needs API access for channel/user membership management; delivery
bots do not. Separate these identities and their secret paths. The controller's
Kubernetes RBAC should cover only its resources/status and permitted namespace
secret bindings, not cluster-admin, arbitrary TokenRequests, MongoDB or exec.
Restrict OpenBao writers per registered product; do not give runtime applications
writer/migration roles. Consider a narrow provisioning service if Rocket.Chat's
Community permissions are too broad for a directly exposed controller identity.

If Rocket.Chat is down, reconciliation remains pending and signup keeps queuing.
If OpenBao/ESO is down, preserve the last verified credential and do not enable a
new unconfigured workload. On namespace deletion, retain chat history and
credentials by default; cleanup/rotation requires a separate approved process.

Start by implementing this state machine over the already-tested APIs, with
fake API boundary tests plus an isolated workspace integration suite. No new
broker or persistent disk is needed. Any future Kubernetes pod should use the
existing cluster and resource limits; standard-disk policy remains unchanged.
