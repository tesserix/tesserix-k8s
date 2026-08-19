# NATS multi-tenant auth rollout (operator / JWT)

Tracks Home-Chef-App#758. Turns the shared anonymous NATS cluster into
per-product isolated accounts using the decentralized **operator/JWT** model
with a **MEMORY resolver** (account JWTs declared in the chart; per-user creds in
GCP Secret Manager → ESO).

All chart scaffolding ships **gated behind `auth.enabled: false`** and is inert
until the steps below are done and the flag is flipped. The chart refuses to
render `auth.enabled: true` without a real operator JWT, so a half-configured
enable cannot reach the cluster.

Accounts: `$SYS`, `HOMECHEF`, `FANZONE`, `DEVAI`, `MARKETPLACE`, `STOCKPILOT`.

## Why this is an atomic cutover (not a gradual drift)

Operator/JWT auth is all-or-nothing: enabling the operator + resolver rejects
anonymous connections **globally**. There is no `no_auth_user` fallback (that is
config-mode only). So every consumer must have creds mounted *before* the flip,
then all cut over together — a brief, auto-recovered reconnect blip (clients
reconnect; homechef's outbox and JetStream lose nothing), not an outage.

## Stage 1 — Bootstrap with nsc (one-time, run locally, NOT in git)

```bash
brew install nats-io/nats-tools/nsc     # or from releases
export NKEYS_PATH=~/.nk NSC_HOME=~/.nsc

# Operator (root of trust). --sys creates the SYS account.
nsc add operator --generate-signing-key --sys HomeChefNATS
nsc edit operator --require-signing-keys \
  --account-jwt-server-url nats://nats.nats.svc.cluster.local:4222

# One account per product, each with its own JetStream slice of the 20Gi disk.
# Tune the numbers to each product's real footprint; total disk <= volume size.
add_acct() {  # name  memGi  diskGi  streams  consumers
  nsc add account "$1"
  nsc edit account "$1" --js-mem-storage "${2}G" --js-disk-storage "${3}G" \
    --js-streams "$4" --js-consumer "$5"
}
add_acct HOMECHEF    1  8  60  600
add_acct FANZONE     1  6  60  600
add_acct DEVAI       1  2  20  200
add_acct MARKETPLACE 1  3  40  400
add_acct STOCKPILOT  1  1  20  200

# One user per account (services in an account share one user/creds; add more
# users if you want per-service revocation). Writes a .creds file each.
for A in HOMECHEF FANZONE DEVAI MARKETPLACE STOCKPILOT; do
  nsc add user -a "$A" "svc-$A"
  nsc generate creds -a "$A" -n "svc-$A" > "/tmp/${A,,}-nats.creds"
done
nsc add user -a SYS sys && nsc generate creds -a SYS -n sys > /tmp/sys-nats.creds
```

### Extract the non-secret JWTs → `values-prod.yaml`

```bash
nsc describe operator --raw                       # -> auth.operatorJWT
nsc describe account SYS --field sub               # -> auth.systemAccountId (A...)
# For each account, its public key and JWT go into auth.accountJWTs:
for A in SYS HOMECHEF FANZONE DEVAI MARKETPLACE STOCKPILOT; do
  echo "$(nsc describe account $A --field sub): $(nsc describe account $A --raw)"
done
```

Paste into `charts/thirdparty/nats/values-prod.yaml`:

```yaml
auth:
  enabled: false            # stays false until Stage 4
  operatorJWT: "eyJ0eXAiOi..."
  systemAccountId: "ACY...SYS"
  accountJWTs:
    "ACY...SYS": "eyJ...sysAcctJWT"
    "ADH...HOMECHEF": "eyJ...homechefAcctJWT"
    # ... one line per account
```

### Store secrets in GCP Secret Manager (never git)

```bash
for A in sys homechef fanzone devai marketplace stockpilot; do
  gcloud secrets create prod-nats-creds-$A --project=tesseracthub-480811 \
    --data-file=/tmp/$A-nats.creds 2>/dev/null || \
  gcloud secrets versions add prod-nats-creds-$A --project=tesseracthub-480811 \
    --data-file=/tmp/$A-nats.creds
done
# Also store the operator + account signing seeds (from ~/.nk) as break-glass.
shred -u /tmp/*-nats.creds
```

## Stage 2 — Chart wiring (server still anonymous)

Already scaffolded, gated off:
- NATS server: `auth.*` values + operator/resolver block in `configmap.yaml`.
- Each consumer chart: an `ExternalSecret` syncing `prod-nats-creds-<product>` to
  a `*-nats-creds` k8s secret, a creds-file volume mount, and `NATS_CREDS`
  pointing at it — all behind the chart's `nats.auth` flag (inert until set).

Deploy these: the creds files mount into pods but clients still connect
anonymously (the server has no operator yet), so nothing changes.

## Stage 3 — Client creds support (app repos)

Every NATS client must use the creds file when `NATS_CREDS` is set. Go
(`nats.UserCredentials(path)`) and the fanzone TS clients each gain a
"creds-if-present" branch. Ship + deploy while the server is still anonymous —
a no-op until cutover (a server without operator ignores offered creds only if
the client also falls back; the branch is: use creds iff NATS_CREDS set).

## Stage 4 — Global cutover (maintenance window)

1. Confirm every consumer pod has its creds file mounted and the creds-aware
   client deployed.
2. Fill the real JWTs in `values-prod.yaml` (Stage 1) and set `auth.enabled: true`.
3. Sync the `nats` app. The server restarts in operator mode; all clients
   reconnect presenting creds. Watch:
   ```bash
   nats --creds /tmp/sys-nats.creds server list         # 3 servers, JS healthy
   nats --creds <homechef-creds> sub 'fanzone.>'        # must be DENIED (isolation proof)
   nats --creds <homechef-creds> account info           # per-account JS limits enforced
   ```

## Rollback

Set `auth.enabled: false` and sync — the server returns to anonymous and every
client reconnects (mounted creds are simply ignored). Instant, server-side only.
