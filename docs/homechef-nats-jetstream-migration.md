# HomeChef NATS / JetStream reliability cutover

Context: `tesserix/Home-Chef-App#131`. The HomeChef API moved from fire-and-forget
core NATS to a reliable backbone — a transactional **outbox** that publishes to
JetStream with PubAck, and **durable consumers** with ack / retry / idempotency /
DLQ. This note covers the one-time infra steps.

## 1. Stream retention change (WorkQueue → Limits) — one-time, manual

The API now declares its streams with `Retention: Limits` (multiple durable
consumers per subject; bounded by age **and** size with `DiscardOld`). NATS
**cannot change a stream's retention policy in place** — `CreateOrUpdateStream`
returns an error and the API logs:

```
NATS stream ORDERS: setup failed (if this is a retention change on an existing
WorkQueue stream, delete the stream once so it is recreated): ...
```

The old `WorkQueuePolicy` streams (`ORDERS NOTIFICATIONS CHEF DELIVERY PAYMENTS
USERS REVIEWS CATERING APPROVALS SUBSCRIPTIONS PROVIDER`) were **never consumed**
by a JetStream consumer, so they hold only undrained backlog — safe to delete.
The API recreates them as Limits streams on next boot.

```bash
# Port-forward a NATS box (read-only debug is allowed; this is a one-time op).
kubectl -n nats exec -it deploy/nats-box -- sh
# Inside, for each stream:
nats stream rm ORDERS NOTIFICATIONS CHEF DELIVERY PAYMENTS USERS REVIEWS \
  CATERING APPROVALS SUBSCRIPTIONS PROVIDER -f
```

Then restart the API pods (or let the next deploy roll them); `setupStreams()`
recreates all streams + the new `DLQ` stream as `Limits`. Fresh / local clusters
need none of this — they come up correct.

> Subjects intentionally NOT captured by any stream (kept core-NATS, real-time):
> `notifications.user.*` (per-user bell) and `delivery.location.*` (live GPS).

## 2. Istio sidecar exclusion (#136)

`charts/apps/homechef-api/values.yaml` restores:

```yaml
traffic.sidecar.istio.io/excludeOutboundPorts: "4222"        # NATS / JetStream
traffic.sidecar.istio.io/excludeOutboundIPRanges: "169.254.169.254/32"  # GCP metadata
```

Without the NATS exclusion, JetStream's long-lived control calls time out through
the proxy. (If the namespace is ambient, also ensure the NetworkPolicy allows TCP
15008 to the pod CIDR — see the ambient-HBONE note.)

## 3. Schema

`outbox_events` + `processed_events` are provisioned idempotently by the
`db-schema-bootstrap` CronJob (`schemas/homechef/homechef/homechef.sql`). No app
migration owns them in production.

## 4. Replicas

`NATS_STREAM_REPLICAS: "3"` in prod values matches the 3-node JetStream HA
StatefulSet so stream data survives a node loss. Local/dev defaults to 1.

## 5. What to watch

- `homechef_outbox_publish_failures_total{subject}` — events dead-lettered after
  exhausting publish retries (rows stay `status='failed'` for replay).
- `homechef_consumer_dead_letters_total{durable}` — poison messages routed to the
  `DLQ` stream (`dlq.<stream>.<durable>`).
- JetStream file-store utilisation — streams are now bounded, but alert anyway.
