# mark8ly onboarding notifications: rollout

This is the production configuration and runbook. Argo/Kargo report live activation.
Scope: new completed mark8ly tenant/store signups to `onboarding-mark8ly` only.

## Target and credentials

- GCP account: `unidevidp@gmail.com`; project: `tesseracthub-480811`.
- Kubernetes context: `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`.
- Workload: namespace `mark8ly`, deployment/Argo application `mark8ly-platform-api`.
- Rocket.Chat: `https://rocketchat.tesserix.app`, namespace `rocketchat`.
- OpenBao KV v2 path: `kv/mark8ly/app/mark8ly-rocketchat-onboarding`.
- Secret properties: `token`, `user_id`, `room_id`.
- ESO target: `mark8ly/mark8ly-rocketchat-onboarding`.

The dedicated service identity uses the built-in bot role restricted to only
`view-joined-room`, because Community edition does not support custom roles.
It is subscribed only to `onboarding-mark8ly`. Its read of `support-mark8ly` and
user-administration API are verified denied; public HTTPS chat access passes.
Keep local interactive login disabled and human Zitadel grants unchanged.

Provision its token through an authorized Rocket.Chat administrator operation,
write it directly to OpenBao, and never print it or put it in a file/commit.
Resolve the real room ID from the existing channel; do not use the display name
as an ID. Preserve an existing identical secret on rerun; never silently rotate
or overwrite an existing different value.

## Approved rollout sequence

1. Obtain approval for committing/merging and the mark8ly production rollout,
   including the dedicated service credential. Recheck the active cloud identity,
   context, RBAC and live revisions before mutation.
2. Merge/build the reviewed mark8ly platform-api code and wait for its image.
   Promote the verified service image through Kargo, which owns live Helm image
   parameters. Wait until every replica runs the compatible binary with
   notifications disabled; it reserves a retryable handler for rolling enablement.
   No database migration is required.
3. Provision and verify the restricted bot and OpenBao secret. Merge the OpenBao
   policy and ExternalSecret changes separately from the workload Helm changes.
   Apply the policy through its owning GitOps app, sync external-secrets and
   verify the ExternalSecret is Ready without displaying its values.
4. The platform-api Argo app has auto-sync enabled: merging its Helm wiring is
   the production rollout, not a harmless staging step. Merge that wiring only
   after the secret is Ready and its image parameter names the verified new image.
   Its rendered environment references the new Kubernetes Secret. Wait for a
   healthy rollout and verify Argo's desired/live revision agreement.
5. Send a clearly labelled synthetic signup payload through the same handler
   twice using a synthetic tenant UUID and `.invalid` email. Verify one message
   in `onboarding-mark8ly` with correct formatting; no real customer backfill.
6. Verify the next real completed onboarding creates one outbox row and one
   channel message. Confirm subsequent login/retried completion adds no message.
   Until then, report live synthetic verification separately from real-signup
   verification. Mobile notification delivery is a separate device check.

This feature uses the existing service, outbox and database. It provisions no
disk and does not change the required standard-HDD storage policy.

## Monitoring and recovery

Check outbox counts/oldest age filtered by kind
`rocketchat.onboarding_completed`. Alert/investigate increasing pending age or
any dead event using the existing operational monitoring. Use aggregate counts,
event IDs and sanitized errors; do not dump payloads/customer details to logs.
Retries use the existing backoff and maximum-attempt policy. After fixing an
outage, requeue only reviewed dead event IDs, preserving their payload and stable
message ID; verify one channel message per event. Never mass-replay all signups.

For an approved rollback, first stop new enqueueing and drain pending events
where possible. Capture IDs/status of pending, in-flight and dead events before
restoring an older binary: older code does not recognize the new event kind and
may dead-letter it. Preserve these rows for replay after restoring the feature.
Use the owning GitOps repository to revert workload configuration/image; do not
delete secrets, messages, customers or outbox history. Credential rotation or
revocation is a separate explicitly approved action.

## Local validation performed

- Platform API: `go test -race ./...`, `go vet ./...`, `go build ./...`.
- Onboarding/outbox: `go test -tags=integration -race -p 1 -count=1
  ./internal/onboarding ./internal/outbox` against disposable PostgreSQL 16 after
  migrations and reference-data seeding.
- `golangci-lint run --new-from-rev=HEAD ./internal/onboarding/...
  ./internal/outbox/... ./pkg/config/... ./cmd/server/...`.
- `uv run --with pytest --with pyyaml python -m pytest
  tests/test_mark8ly_rocketchat.py tests/test_rocketchat_manifests.py -q`.
- `helm lint charts/apps/mark8ly-platform-api`; `git diff --check` in both repos.

## Reusable procedure

See [product onboarding and future operator design](rocketchat-product-onboarding.md)
for channel creation, Community permissions, API calls, credential lifecycle,
application contract, reconciliation states and recovery. Registration metadata
is in [`config/rocketchat/products.yaml`](../config/rocketchat/products.yaml).

Bot ID: `2LnQXGYY2XPsJMCLZ`; room ID: `6adeda38dfe0bc336c6d4c03`.
Temporary administrative/writer sessions and provisioning grants were removed.
