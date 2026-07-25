# HomeChef PII column encryption — migration runbook (#710)

## Where this stands

| Phase | What it does | Status |
|-------|--------------|--------|
| P1 | Dual-write: `*_enc` gets real ciphertext, `*_bidx` gets blind indexes | **Committed**, awaiting merge/deploy |
| P2 | Backfill existing rows so their companions are not stale plaintext | **Blocked on P1 being live** |
| P3 | Reads move to `_enc`; email/phone lookups move to `_bidx` | Not started |
| P4 | Drop the plaintext columns | Not started |

**Until P4, the plaintext is still there and still readable.** P1 on its own
changes nothing for an attacker holding a database dump. Do not report this as
"PII is encrypted" before P3 lands.

## Why the phases cannot be collapsed

They are strictly sequential, and the ordering is not stylistic:

- P2 cannot run before P1 is deployed, because the backfill's whole job is to
  re-save rows *through* an encryption layer that is only active once the flag
  is on.
- P3 cannot ship before P2 completes. Reads would move to `email_enc` and
  lookups to `email_bidx` — but rows written while the flag was off hold
  **plaintext in `email_enc` and an empty `email_bidx`**. Any such account
  would fail its login lookup immediately.

Verified in prod on 2026-07-26:

```
SELECT left(email_enc,7), email_enc LIKE 'enc:v1:%', email_enc = email,
       length(coalesce(email_bidx,'')) FROM users;
-- john.do | f | t | 0
-- unidevi | f | t | 0
```

Both rows: `email_enc` is a plaintext copy, `email_bidx` empty. Exactly the
state that breaks P3 if skipped.

## P2 — backfill

Scope is currently **2 user rows**; every other PII-bearing table is empty
(`customer_profiles`, `addresses`, `orders` all 0). Prod was reset for launch on
2026-07-25, so this is the cheapest this migration will ever be. Do it now
rather than at 10k users.

The companions are written by a GORM `BeforeSave` hook, so the backfill is a
read-then-save per row — not an `UPDATE`. A plain SQL update cannot work: it
would bypass the hook and the `driver.Valuer` boundary where encryption
actually happens.

Verify afterwards — every row must report `t` and a non-zero bidx length:

```sql
SELECT count(*) FILTER (WHERE email_enc LIKE 'enc:v1:%') AS encrypted,
       count(*) FILTER (WHERE coalesce(email_bidx,'') <> '') AS indexed,
       count(*) AS total
FROM users;
```

Watch for map-based updates, which silently skip the hook. The limitation is
documented in `models/pii_dualwrite.go`:

```go
db.Model(&u).Updates(map[string]any{"phone": p})   // companions NOT synced
```

`models.PIIUpdates()` exists to patch those call sites — `handlers/upload.go`,
`handlers/customer.go`, `services/provider.go`.

## P3 — move reads to the encrypted columns

Smaller than it looks. `models.EncryptedString` implements **both**
`driver.Valuer` (encrypt on write) and `sql.Scanner` (decrypt on read), so
decryption is transparent at the driver boundary. The ~240 places that read
`user.Email` and friends need **no changes at all**.

The actual work:

1. Repoint the model fields at the `_enc` columns and type them
   `EncryptedString`.
2. Rewrite the **6 lookup sites across 5 files** that currently filter on
   plaintext `email` / `phone` to filter on `email_bidx` / `phone_bidx` via
   `piicrypto.BlindIndex(value)`. These are the only queries that cannot work
   over ciphertext — AES-GCM is not order- or equality-preserving, which is
   precisely why the blind index exists.
   ```
   grep -rnE '(Where|First|Find|Take)\([^)]*"(email|phone|lower\(email\))' --include='*.go' .
   ```
3. Keep `idx_users_email_bidx` / `idx_users_phone_bidx` in the query plan —
   they already exist, so lookups stay indexed rather than degrading to a scan.

Uniqueness carries over: `piicrypto.BlindIndex` normalises (lowercase + trim),
which preserves the existing `lower(email)` semantics.

## P4 — drop the plaintext columns

Only after P3 has run in prod long enough to be confident. Schema changes belong
in `charts/apps/db-schema-bootstrap/schemas/homechef/homechef/homechef_db.sql`,
never in the app repo. This is the phase that actually removes the exposure.

## Rollback

Set `PII_ENCRYPTION_ENABLED: "false"` in
`charts/apps/homechef-api/values-prod.yaml`. Safe at P1/P2 because ciphertext is
prefix-tagged (`enc:v1:`) and `DecryptPII` passes untagged plaintext straight
through, so mixed-state columns keep reading correctly.

**Rollback stops being free once P3 ships** — at that point reads depend on the
encrypted columns, and disabling the flag makes `DecryptPII` hand back raw
ciphertext. Treat the P3 deploy as the point of no easy return.

## Startup hazard

`main.go:150` is `log.Fatalf`: if Secret Manager or KMS is unreachable, or the
unwrapped DEK is not exactly 32 bytes, the API exits at boot. The rollout is
nonetheless safe — `replicas: 2` with `maxUnavailable: 25%` floors to 0, so a
crash-looping pod never becomes Ready and the old pods keep serving. A bad init
stalls the rollout instead of dropping traffic.

One prerequisite remains **unverified**: that the wrapped DEK decrypts to
exactly 32 bytes. IAM and secret existence were confirmed; the decrypt itself
was not run, since it materialises key material. Confirm before merging:

```bash
gcloud secrets versions access latest --secret=prod-homechef-pii-dek-wrapped \
  --project=tesseracthub-480811 | tr -d '\n' | base64 -d > /tmp/w.bin
gcloud kms decrypt --key=pii-dek --keyring=homechef-pii --location=asia-south1 \
  --project=tesseracthub-480811 --ciphertext-file=/tmp/w.bin \
  --plaintext-file=/tmp/d.bin
wc -c < /tmp/d.bin    # must be exactly 32
shred -u /tmp/w.bin /tmp/d.bin
```
