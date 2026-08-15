# Tenant secrets — direct OpenBao, not ESO

`openbao-secrets.md` describes one access pattern: External Secrets pulls a
value from OpenBao into a Kubernetes Secret, and the pod reads it from the
filesystem or the environment. Two properties define it — **it happens before
the process starts**, and **it refreshes hourly**.

Both are right for a database password. Both are wrong the moment a customer
pastes a Jira token into your product's settings page and expects the next
sync to use it.

This file is the design for the second path: a product API that reads and
writes its tenants' secrets **directly against OpenBao, at request time**, under
a naming standard that makes each tenant's prefix unambiguous and a token model
that makes cross-tenant access impossible rather than merely unlikely.

Read [`openbao-secrets.md`](openbao-secrets.md) for the cluster, the trust chain
and the ESO wiring. Read [`tenancy-model.md`](tenancy-model.md) for what a
tenant is and which tier may hold secrets at all.

---

## 1. Why ESO cannot do this job

Not a criticism of ESO — a different job.

| | ESO path | Runtime path |
|---|---|---|
| Trigger | Pod start, then a poll | A user clicking Save |
| Latency to effect | Up to an hour | Immediate |
| Who writes | An operator, through the console | The tenant, through the product |
| Cardinality | One secret per app | Thousands, one prefix per tenant |
| Failure if late | Pod won't start — loud | Silent: tenant thinks it saved |

The cardinality row is the one that ends the argument. ESO materialises each
secret as a Kubernetes Secret object. A thousand tenants with three credentials
each is three thousand Secret objects and three thousand `ExternalSecret`
resources, all in one namespace, all refreshing hourly against OpenBao — for
data that only one HTTP handler ever reads, on demand, for one tenant at a time.

**Keep both paths. They carry different things:**

```
   ┌────────────────────────────────────────────────────────────────┐
   │ PLATFORM secrets — must exist before the process does          │
   │   DB password · room-token HMAC key · GHCR token · TLS         │
   │                                                                │
   │   GCP Secret Manager ──► ESO ──► K8s Secret ──► pod env        │
   └────────────────────────────────────────────────────────────────┘

   ┌────────────────────────────────────────────────────────────────┐
   │ TENANT secrets — created by customers, at any time             │
   │   Acme's Jira token · Slack token · webhook signing secret     │
   │                                                                │
   │   pod ──── Kubernetes auth ────► OpenBao, per request          │
   │            (no bootstrap secret needed — the projected         │
   │             ServiceAccount token is the credential)            │
   └────────────────────────────────────────────────────────────────┘
```

There is no chicken-and-egg problem in the second path. Kubernetes auth
authenticates the pod with its own projected ServiceAccount token, so the app
needs **no pre-provisioned secret** to reach OpenBao. This is the part that makes
"ESO for everything" unnecessary rather than merely inconvenient.

---

## 2. OpenBao namespaces — available, and the right primitive

`openbao-secrets.md` predates this: OpenBao gained **namespaces** in 2.3, and
2.5/2.6 added **sealable namespaces**, where a tenant's data is encrypted under
its own key and can be sealed independently of the platform seal. We run 2.6.1,
so all of it is available today.

A namespace is a full isolation boundary — its own secrets engines, auth
methods, tokens, policies and metadata. That is much stronger than a path
prefix, and it introduces a choice.

### The decision rule

| Boundary | Use a… | Why |
|---|---|---|
| Product (`planning-poker`, `hms`) | **Namespace** | Always. Isolates each product's auth roles, policies and mounts. A mistake in one product's policy cannot name another product's path. |
| Ordinary tenant | **Path prefix + per-tenant policy** | Cheap, unlimited cardinality, one prefix to delete at offboarding. |
| Enterprise tenant demanding cryptographic isolation | **Sealable child namespace** | Their own encryption key, their own seal. Sell it as a tier — "hold your own key" is a real procurement checkbox. |

**Do not default to a namespace per tenant.** Namespaces carry mounts, policies
and storage of their own; thousands of them is an operational problem you will
not enjoy. Path-per-tenant is the default, and the namespace escape hatch exists
for the customer whose security review demands it.

---

## 3. The naming standard

Everything below is derived, never typed by a human, and never taken from a
request body.

```
  <product namespace>  /  <mount>  /  <tenant-id>  /  <scope>  /  <name>

  products/planning-poker  /  tenants  /  9f3c…d21  /  integrations  /  jira
  products/planning-poker  /  tenants  /  9f3c…d21  /  sso           /  okta
  products/planning-poker  /  tenants  /  9f3c…d21  /  users/7ab…    /  pat
  products/hms             /  tenants  /  1e77…904  /  webhooks      /  pacs
```

As an API path, with KV v2's `data/` infix:

```
POST /v1/products/planning-poker/tenants/data/9f3c…d21/integrations/jira
     X-Vault-Namespace: products/planning-poker      (or the path form above)
```

Alongside `tenants/`, each product namespace gets a `platform/` mount for the
product's own secrets — the ones ESO still reads. Two mounts, two access
patterns, no overlap.

### Five rules that keep it unambiguous

1. **The tenant id is the immutable UUID, never the slug.** Acme renaming itself
   must not orphan its secrets. Slugs are for URLs; ids are for paths.
2. **`scope` is a closed vocabulary** — `integrations`, `sso`, `webhooks`,
   `byok`, `users/<userId>`. Closed, so the settings UI can enumerate what a
   tenant holds without a schema lookup, and so a typo creates an error rather
   than a new category.
3. **`name` is validated against `^[a-z0-9][a-z0-9-]{0,63}$` server-side.** The
   path is built from user input; without this, `../` walks out of the tenant's
   prefix. This is the single highest-severity bug available in this design.
4. **The tenant id in the path comes from the verified principal**, never from
   the URL or body — the same invariant as `tenancy-model.md` § 2, one layer
   down. A request writing to Acme's prefix must carry a token proving Acme.
5. **No environment segment.** Environments are separate clusters. Putting
   `prod/` in the path invites a staging deploy pointed at a prod prefix.

---

## 4. Authorization — a token that cannot name another tenant

Path conventions organise. They do not enforce. If the product API holds one
token good for `tenants/data/*`, then every tenant's secrets are one missing
`WHERE`-equivalent away, and we are back to trusting handler code.

The fix is that **the token used for the operation is scoped to one tenant**,
minted per request from a policy created when the tenant was onboarded.

```
  ┌──────────────────────────────────────────────────────────────────┐
  │ ONCE, at tenant onboarding (identity-service / tenancy service)  │
  │                                                                  │
  │   PUT sys/policies/acl/tenant-9f3c…d21                           │
  │     path "tenants/data/9f3c…d21/*"     { create, read,           │
  │                                          update, delete }        │
  │     path "tenants/metadata/9f3c…d21/*" { read, list, delete }    │
  └──────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────┐
  │ ONCE PER POD, at startup and on renewal                          │
  │                                                                  │
  │   POST auth/kubernetes/login   (projected SA token)              │
  │     → parent token, policy `pp-api-broker`                       │
  │       may create child tokens; may NOT read tenants/data/*       │
  └──────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────┐
  │ PER REQUEST (cacheable for the child token's TTL)                │
  │                                                                  │
  │   tenantID ← verified Zitadel claim, NOT the request             │
  │   POST auth/token/create                                         │
  │     policies = ["tenant-9f3c…d21"]                               │
  │     ttl = 60s, num_uses = 2, renewable = false                   │
  │     → child token, then read/write, then discard                 │
  └──────────────────────────────────────────────────────────────────┘
```

The property this buys: **the broker token cannot read any tenant's secret, and
the child token cannot name any tenant but one.** A path-construction bug fails
with a 403 from OpenBao instead of returning someone else's Jira credential. The
audit log records which tenant policy was used, which is what turns "we have
logs" into an answer at a compliance review.

Cost is one extra round trip. Cache child tokens per tenant for their TTL and it
disappears under any real traffic.

### What the broker policy must not have

- Never `tenants/data/*` — the whole point is that the long-lived token is
  useless on its own.
- Never `sys/policies/acl/*` write. **Provisioning is a different service from
  consumption.** The product API creates no policies; it only spends them. A
  compromised product API must not be able to mint itself a policy for
  every tenant.

---

## 5. Provisioning a tenant's secret store

At tenant creation — the same transaction as the Zitadel org and the product's
tenant row (`identity-control-plane.md` § 5):

1. Create the policy `tenant-<uuid>` in the product's namespace.
2. Write a marker at `tenants/data/<uuid>/.meta` so the prefix exists and
   `list` returns something sane before the tenant saves anything.
3. Record in the tenant row that provisioning succeeded. If step 1 fails, the
   tenant must not be marked ready — a tenant who can sign in but cannot save a
   credential looks like a product bug and is reported as one.

Offboarding is the mirror image and is the reason the prefix convention earns
its keep: delete `tenants/metadata/<uuid>/` (KV v2 metadata delete removes all
versions), then delete the policy. One prefix, one policy, nothing stranded.

**Both operations write to OpenBao, and the stored root token is revoked with
`generate-root` returning 403.** So the provisioning service needs its own
Kubernetes auth role with `sys/policies/acl/tenant-*` write — created, once,
through the console. That console step is unavoidable; script the policy
document into git so what exists is reviewable.

---

## 6. Rules for the product API

**Never return a stored secret.** Show `••••4f2a` and a *Replace* button. A read
endpoint over tenant credentials is an exfiltration endpoint with a nice UI. The
only reader is the server-side code that calls the third-party API.

**Never cache plaintext in Postgres**, encrypted or otherwise. If the value ends
up back in the product's database, the move to OpenBao bought an audit log and
nothing else. In-memory, keyed by tenant, TTL ≤ 60s, never logged, never in an
error message.

**Fail closed.** An OpenBao error is a 503, never a fallback to an empty
credential or a cached copy past its TTL. Same rule HMS applies to OpenFGA.

**Apply a quota.** OpenBao supports rate limit quotas per namespace and path; one
tenant scripting their settings page must not exhaust the cluster for everyone.

**Version, and keep a few.** KV v2 keeps history. A tenant who pastes the wrong
token and breaks their integration at 5pm is the reason to keep the last three
versions rather than one.

---

## 7. What this changes in the existing docs

`openbao-secrets.md` states *"Read only. Nothing in the cluster writes `kv/`
except the admin console."* That rule was correct when ESO was the only
consumer, and it is the rule this design deliberately carves an exception from.
The exception is narrow and worth stating in those terms:

- Writes are confined to one mount (`tenants/`) inside one product namespace.
- The writing identity is a per-tenant policy, not the application.
- The application's own long-lived token has no read or write on that mount.
- Platform secrets remain read-only via ESO, unchanged.

Precedent already exists: `secret-service` holds `create`/`update` under its own
policy today. This generalises that from one admin console to per-tenant,
per-request scope.

---

## 8. Build order

1. **A product namespace and its two mounts** for one product, applied through
   the existing declarative bootstrap in `charts/thirdparty/openbao/values.yaml`
   — policies and Kubernetes auth roles are already expressed there.
2. **The broker role and per-tenant policy template**, plus the console-created
   provisioning role (§ 5).
3. **A small Go client** — `Login`, `TokenForTenant`, `Get`, `Put`, `Delete` —
   with the path builder and its validation in one place, tested against a
   traversal attempt. Every product uses it; nobody hand-builds a path.
4. **Migrate `integration_configs.token`** in Planning Poker: dual-write, verify,
   then drop the column and `internal/secrets`.
5. **Sealable namespaces** only when a customer asks and will pay for it.

## Failure modes

| What you see | Cause |
|---|---|
| Tenant saves a token, sync still uses the old one | Reading through ESO's hourly path instead of the runtime path (§ 1) |
| 403 on a tenant's own prefix | Child token minted with the wrong policy name, or the tenant was never provisioned (§ 5) |
| One tenant reads another's secret | Tenant id taken from the request rather than the verified principal (§ 3, rule 4) |
| A name with `../` reaches OpenBao | Missing server-side name validation (§ 3, rule 3) |
| Broker token works for everything | Broker policy was granted `tenants/data/*` — it must not be (§ 4) |
| Secrets survive tenant deletion | Deleted `data/` but not `metadata/`; KV v2 keeps versions under metadata (§ 5) |
| Renaming a tenant orphans its secrets | Path built from the slug instead of the immutable id (§ 3, rule 1) |
