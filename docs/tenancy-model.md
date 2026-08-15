# Tenancy model — ephemeral, team, and onboarded organization

[`identity-control-plane.md`](identity-control-plane.md) describes one shape:
an enterprise buys the product, gets a Zitadel organization, connects their own
SSO. That is HMS, and it is the *easy* case — every user is authenticated before
they touch anything.

Planning Poker is the hard case, and it is the shape most of our products will
actually have. Someone with no account opens a room, sends a link to four
colleagues, they estimate for twenty minutes, and the whole thing should
evaporate afterwards. No signup, no org, no SSO — but *also* no way for a
stranger to read that session. And when the same team's company later wants
Planning Poker properly — persistent history, their own SSO, their own Jira
token — they must be able to onboard themselves onto exactly the same
deployment.

**One product, three tenancy tiers, one codebase.** This file defines the tiers,
the isolation rule for each, the data lifecycle, and where secrets go.

---

## 1. The three tiers

| | **T0 — Ephemeral** | **T1 — Team** | **T2 — Organization** |
|---|---|---|---|
| Who | Anonymous guests | Signed-in individuals | An onboarded company |
| Identity | None. A participant is a name typed into a box. | Zitadel user, personal org | Zitadel org, their own SSO |
| Tenant boundary | **The room** | The team | The organization |
| Isolation enforced by | Room-scoped capability token | `tenant_id` + RLS | `tenant_id` + RLS |
| Data lifetime | Purged 10 min after the session ends | Retained | Retained, their retention policy |
| Secrets | None. Cannot hold any. | Tenant path in OpenBao | Tenant path in OpenBao |
| Cost to enter | Zero — open a URL | A sign-in | Self-serve onboarding (§ 6) |

The tiers are a ladder, not variants: a T0 room can be claimed into T1 or T2
while it is still alive (§ 5). Nothing is rebuilt when a team upgrades.

**T0 is the product's front door, and it is also the whole security problem.**
Everything below exists because T0 has no identity to authorize against.

---

## 2. T0 — authorization without identity

In T0 there is no user, so there is nothing to look up in a permissions table.
The only thing that can carry authority is **the token itself**. This is a
capability model: possession of an unforgeable, narrowly-scoped token *is* the
permission.

Planning Poker already has the right primitive. `api/internal/auth/token.go`
mints an HMAC-signed `participantID|roomID`:

```
   join room ABC123
        │
        ▼
 ┌──────────────────────────────────────────────────────┐
 │  server mints  token = base64(participantID|roomID)  │
 │                        + "." + HMAC-SHA256(payload)  │
 └──────────────────────────────────────────────────────┘
        │
        ▼
   every later request carries it; the server reads roomID
   FROM THE TOKEN and never from the URL or the body
```

That last line is the whole rule, and it is worth stating as an invariant:

> **The room id used in every query comes from the verified token, never from
> the request.** If a handler reads `:roomID` from the path and trusts it, the
> capability model is gone and any participant can read any room by editing a
> URL.

### The room code is not a credential

`rooms.code` is short, shareable, and pasted into Slack. Treat it as a *lookup
key that lets you ask to join*, never as proof you may read. The join step is
what mints a capability; the code alone must return nothing but "this room
exists, what is your name?".

This distinction is what makes "I started a game" not imply "I can see other
people's games". The code gets you a door. The token gets you the room. Different
rooms mint different tokens, and a token names exactly one room.

### Four gaps in the current implementation

Found while reading the code, all in `api/internal/auth/token.go` and the
schema in `api/internal/store/postgres.go`:

**1. The room token has no expiry.** `Claims` is `{ParticipantID, RoomID}` and
nothing else. `rooms.expires_at` bounds the *room*, but the token is valid
forever against whatever that room id refers to. Compare `UserClaims` in
`user_token.go`, which does carry `ExpiresAt` and is checked. Add an expiry to
the room token, no longer than the room's own.

**2. There is no revocation.** A participant who leaves — or is removed —
keeps a working token. Add a per-room epoch (a random value in `rooms`, bumped
on eviction) into the signed payload and compare on verify. Cheap, and it makes
"remove participant" mean something.

**3. One HMAC key for every room, with no rotation path.** Compromise of the
signing secret forges a token for every room that has ever existed. The epoch
above limits the blast radius; a documented rotation procedure closes it.

**4. `rooms.tenant_id` is nullable and there is no RLS.** T0 rooms have
`tenant_id IS NULL`. Isolation therefore rests entirely on every handler
remembering its `WHERE` clause — the exact failure HMS avoids with forced RLS.
See § 4.

---

## 3. Data lifecycle — "gone in 10 minutes" needs a definition

The requirement is that a T0 session disappears shortly after it is finished.
"Finished" is not self-evident, and the honest failure mode is a room nobody
closes because everyone shut their laptop.

```
 CREATED ──────────► ACTIVE ──────────► CLOSED ──────────► PURGED
    │                  │  host clicks       │  +10 min        (rows deleted)
    │                  │  "end session"     │
    │                  │                    │
    │                  └─ no participant ───┘
    │                     for 30 min
    │                     (implicit close)
    │
    └─ never joined, +2h ──────────────────────────────────► PURGED
```

Three transitions, because only the first is under anyone's control:

- **Explicit close.** The host ends the session. `closed_at` is set. This column
  already exists.
- **Implicit close by inactivity.** No connected participant for 30 minutes.
  Without this, a forgotten room is retained forever and the promise is false.
- **Absolute cap.** `rooms.expires_at` already defaults to `now() + 2 hours`.
  It stays as the backstop for rooms that were created and never used.

**Purge is a delete, not a flag.** `participants`, `issues`, `rounds`, `votes`
and `comments` all cascade from `rooms(id)`, so a single `DELETE FROM rooms`
removes the session. That cascade is already in the schema and is the reason
this is cheap.

Run it as a CronJob in the product's own chart, every 5 minutes, and have it
emit a count so an outage of the purger is visible:

```sql
DELETE FROM rooms
WHERE tenant_id IS NULL
  AND (closed_at < now() - interval '10 minutes' OR expires_at < now());
```

`tenant_id IS NULL` is doing load-bearing work: **T0 rows are purged, T1/T2 rows
never are by this job.** A tenant's retention is their policy, not ours.

Aggregates worth keeping (how many rooms, how many votes) must be counted into a
separate table *before* the delete, and must not carry room ids, participant
names, or issue titles. Anonymous means anonymous; a "statistics" table that
retains the estimate history of a purged room is the same data with a different
name.

---

## 4. Isolation — make the database enforce it

Handler-enforced isolation is one forgotten `WHERE` clause from a cross-tenant
leak, and it will be forgotten, because there will eventually be dozens of
queries. HMS already went the other way: forced RLS on every tenant table, with
the tenant id set from the verified principal.

Planning Poker should follow, and the nullable `tenant_id` is the obstacle.
Nullable columns do not compare the way people expect — `tenant_id = NULL` is
never true, so a naive RLS policy silently matches nothing (or, written the
other way, everything).

**Use a sentinel instead of NULL.** A reserved all-zeroes UUID for "ephemeral,
scoped by capability token only", `tenant_id` made `NOT NULL`, and then a single
policy that works uniformly:

```sql
ALTER TABLE rooms ALTER COLUMN tenant_id SET DEFAULT '00000000-0000-0000-0000-000000000000';
UPDATE rooms SET tenant_id = '000...0' WHERE tenant_id IS NULL;
ALTER TABLE rooms ALTER COLUMN tenant_id SET NOT NULL;

ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE rooms FORCE ROW LEVEL SECURITY;
CREATE POLICY rooms_tenant ON rooms
  USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

For T0 the app sets `app.tenant_id` to the sentinel, and **the room-scoped
capability token remains the actual boundary** — RLS is not protecting one guest
room from another, it is protecting every tenant's data from the guest tier and
from each other. Two different mechanisms for two different threats:

| Threat | Stopped by |
|---|---|
| Guest reads another guest's room | Capability token names one room (§ 2) |
| Guest reads a tenant's data | RLS — sentinel ≠ any real tenant id |
| Tenant A reads tenant B | RLS |
| A handler forgets its `WHERE` | RLS, which is the point of `FORCE` |

`FORCE ROW LEVEL SECURITY` matters specifically because the app connects as the
table owner, and owners bypass RLS without it.

### While here: the schema is in the wrong repo

`api/internal/store/postgres.go` holds ~20 `CREATE TABLE` statements executed at
boot. The workspace rule is that schemas live in
`tesserix-k8s/charts/apps/db-schema-bootstrap/schemas/<project>/<database>/` and
app repos hold ORM models only. Planning Poker has no directory there. The RLS
work above is the natural moment to move it, because RLS policies are exactly
the kind of thing that must not depend on which pod booted first.

---

## 5. Upgrading a tier — claiming a room

A team using T0 who decide they want to keep their history must not have to
re-enter anything. While a room is alive, a signed-in user may **claim** it:

```
   T0 room (tenant_id = sentinel)
        │
        │  signed-in user with a tenant clicks "Save this session"
        ▼
   UPDATE rooms SET tenant_id = <their tenant>, closed_at = NULL
        │
        ▼
   T1/T2 room — excluded from the purge job by the same predicate
```

Two rules that keep this honest:

- **Only a participant of the room may claim it**, proven by their capability
  token, presented alongside their user token. Otherwise room codes become a way
  to hoover up other people's sessions.
- **Claiming is one-way and visible.** Every participant sees that the session
  is now retained by *Acme*, because the privacy promise they joined under has
  changed. A silent upgrade is a surprise, and the surprise is "the estimates I
  gave anonymously are now in my employer's account".

Anonymous participants in a claimed room stay anonymous — claiming retains the
session, it does not retroactively identify who was in it.

---

## 6. T2 — a company onboards itself

This is the flow from [`identity-control-plane.md`](identity-control-plane.md)
§ 5, unchanged. Planning Poker is a second `project` in Zitadel; Acme is an
`organization`; `identity-service` creates the org, grants the project, and
Acme's admin verifies their domain and connects Okta — all without a deploy.

What is specific to Planning Poker is what happens on the product side once the
grant exists:

1. A tenant row keyed to the Zitadel org id, exactly as HMS does.
2. Their OpenBao path is provisioned (§ 7) — before they can save a single
   integration credential.
3. Their retention policy replaces the 10-minute purge for their rooms.
4. Their Jira/Slack integrations move from per-room to per-tenant.

The existing `tenants`, `tenant_users`, `user_sessions` and refresh-token tables
in Planning Poker are a **parallel identity system** to Zitadel. That is fine for
now and should not be extended: as T2 arrives, users and sessions become
Zitadel's, and these tables shrink to a tenant record plus a membership cache.
Building more of a homegrown IdP into the product is work that will be deleted.

---

## 7. Secrets — the rule, generalized

The estate rule is in `CLAUDE.md` and does not change: **platform secrets to GCP
Secret Manager, customer secrets to OpenBao.** Planning Poker makes it concrete,
because a tenant's Jira token is unambiguously a customer secret.

| Secret | Whose | Store |
|---|---|---|
| The room-token HMAC signing key | Platform | GCP Secret Manager |
| Database credentials, GHCR token | Platform | GCP Secret Manager |
| Our own Slack app's client id/secret | Platform | GCP Secret Manager |
| **Acme's Jira API token** | Tenant | **OpenBao** |
| **Acme's Slack workspace access token** | Tenant | **OpenBao** |
| Acme's SSO client secret | Tenant | OpenBao (or straight into Zitadel) |

Path convention from [`openbao-secrets.md`](openbao-secrets.md):

```
kv/<namespace>/<app>/<tenant-id>/<secret-name>
kv/planning-poker/planning-poker-api/acme/jira-token
```

The policy grant stops at `kv/data/planning-poker/planning-poker-api/*`, and a
tenant delete is a delete of one prefix.

### Today this is app-encrypted in Postgres, and that has to move

`integration_configs.token` holds the credential, encrypted app-side with
AES-GCM under a key derived in `api/internal/secrets/secrets.go`. That is better
than plaintext, and it is still the product holding every tenant's credentials in
one table under one key. Moving them to OpenBao gets per-tenant path isolation,
an audit trail, and a delete that actually deletes.

### The problem nobody has solved yet: OpenBao is read-only here

`openbao-secrets.md` is explicit — *"Read only. Nothing in the cluster writes
`kv/` except the admin console"* — and secrets reach pods through ESO with an
hourly refresh. Both properties are correct for platform secrets and **wrong for
this use case**:

- A tenant pasting a Jira token expects it to work immediately, not within the
  hour.
- The write comes from the product at runtime, not from an operator in a console.

So T1/T2 secrets need a second path alongside ESO, and it should be scoped as
narrowly as possible:

```
   ESO path (unchanged)              Runtime path (new)
   platform secrets                  tenant secrets
        │                                 │
   OpenBao ──► K8s Secret ──► pod     pod ──► OpenBao (direct, per request)
        hourly refresh                  Kubernetes auth, SA-bound,
                                        write scoped to
                                        kv/data/planning-poker/planning-poker-api/*
```

Conditions on the new path, all of which need to hold before it ships:

- **A separate OpenBao role and policy** from the app's ESO read role, granting
  `create`/`update` on that one prefix and nothing else. Never `kv/data/*`.
- **The tenant id in the path comes from the verified principal**, never from
  the request body. This is the § 2 invariant again, one layer down: a tenant
  writing to `.../acme/` must be Acme.
- **The product never returns a stored secret.** Write-only from the UI's
  perspective; show `••••1234` and a *Replace* button. A read endpoint on tenant
  credentials is an exfiltration endpoint.
- **No caching in the product's database**, not even encrypted — otherwise the
  move has bought nothing.

Note the operational constraint: the stored OpenBao root token is revoked and
`generate-root` returns 403, so **creating this policy and role is a console
action**, not something a chart can do. Budget for it as a manual step, and
script the policy document into git so what is in the console is reviewable.

---

## 8. What to build, in order

Each step is independently shippable, and the first three are corrections to
what exists rather than new surface.

1. **Room token expiry + per-room epoch** (`auth/token.go`). Small, and it closes
   the "token outlives the room, no revocation" gap. Test first: a token for a
   closed room must fail.
2. **The purge job.** Explicit close, inactivity close, absolute cap, and the
   `tenant_id`-sentinel predicate. This is what makes the ephemeral promise real.
3. **Schema into `db-schema-bootstrap`, then sentinel + forced RLS.** In that
   order — RLS policies should not be created by whichever pod booted first.
4. **Room claiming**, with participant proof and visible notice.
5. **Tenant secrets to OpenBao**, including the runtime write role. Needs the
   console step above.
6. **T2 onboarding**, reusing `identity-service` — no Planning-Poker-specific
   work beyond the tenant row and retention policy.

## Failure modes

| What you see | Cause |
|---|---|
| A participant can read another room | A handler read the room id from the URL instead of the token (§ 2) |
| A removed participant still receives updates | No epoch in the token; nothing revokes (§ 2) |
| Guest rooms accumulate forever | Only explicit close is implemented; nobody clicks it (§ 3) |
| A tenant's rooms vanish after 10 minutes | Purge predicate lost its `tenant_id` sentinel check (§ 3) |
| RLS policy matches nothing | `tenant_id` still nullable — `= NULL` is never true (§ 4) |
| RLS silently not enforced | `FORCE ROW LEVEL SECURITY` missing; the app connects as table owner (§ 4) |
| Tenant sees a stale integration token | Read via ESO's hourly refresh instead of the runtime path (§ 7) |
| One tenant writes another's secret path | Tenant id taken from the request rather than the principal (§ 7) |
