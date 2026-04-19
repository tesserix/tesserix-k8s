# storefront-gate Cloudflare Worker

Intercepts `*.mark8ly.com` requests and serves a branded "store closed" page
for subscriptions in `store_closed` / `pending_hard_delete`, a 404 for
`hard_deleted`, and passes through to the origin for everyone else.

Spec: [`mark8ly/docs/superpowers/specs/2026-04-17-subscription-model-design.md`](../../../mark8ly/docs/superpowers/specs/2026-04-17-subscription-model-design.md) §5.3, §5.4.

## Routing decision

| Subscription status                                    | Edge response                                                         |
| ------------------------------------------------------ | --------------------------------------------------------------------- |
| `signup` / `trialing` / `active`                       | pass-through to origin                                                |
| `past_due` / `payment_action_required` / `cancel_scheduled` | pass-through (storefront stays live while merchant resolves payment)  |
| `expired`                                              | pass-through (day 0–13 grace, §5.3)                                   |
| `store_closed` / `pending_hard_delete`                 | 200 OK, branded `closed.html`, `X-Robots-Tag: noindex`                |
| `hard_deleted`                                         | 404 Not Found, `X-Robots-Tag: noindex`                                |
| origin 5xx / fetch failure / unknown host              | pass-through (fail-open)                                              |

## Local dev

```bash
npm install
npm run dev          # wrangler dev --local
npm test             # vitest (interpolate + status + worker)
npm run typecheck    # tsc --noEmit
```

## Deploy

```bash
# One-time per environment:
wrangler secret put INTERNAL_API_TOKEN

# Create the KV namespace and paste the IDs into wrangler.toml:
wrangler kv:namespace create STATUS_KV
wrangler kv:namespace create STATUS_KV --preview

npm run deploy
```

## Cache invalidation (same-day reopen)

KV entries live for 15 minutes. When P11's reactivation path moves a store
back to `active`, it must `DELETE` the cache key `status:<host>` via a
follow-up internal admin endpoint (tracked in P11 follow-up; not blocking
this PR).

## Failure mode philosophy

Every failure mode (KV miss, fetch throw, origin 5xx, JSON parse error) falls
through to `fetch(request)`. A broken edge check must never take a live store
down. The trade-off: a few seconds of stale "live storefront" rendering for a
genuinely closed store is acceptable; even one second of "closed page" for a
genuinely live store is not.
