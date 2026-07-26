# Security & cost audit — 2026-07-26

Scope: HomeChef (`Home-Chef-App`), mark8ly, `tesserix-k8s` infrastructure, and
all 19 GCS buckets in `tesseracthub-480811`. Static source review plus
non-destructive live probes; no exploit attempts against production data.

This document exists so the findings can be re-checked later. Every claim below
was verified against the live cluster or the source, not inferred — where
something was *not* verified, it says so.

---

## 1. Security findings

### 1.1 PII stored in plaintext — HIGH — phase 1 fixed, phases 2-4 open

`apps/api/piicrypto` implements full KMS envelope encryption (AES-256-GCM under
a KMS-wrapped DEK, blind indexes for searchable fields). The KMS key and both
secrets **already existed**; `PII_ENCRYPTION_ENABLED` simply defaulted to
`false` (`config/config.go:277`) and appeared in none of the 58 env vars on the
live deployment. The system was built, provisioned, and never switched on.

**The important nuance:** turning the flag on does *not* protect the data. Per
`models/pii_dualwrite.go` this is phase 1 of 4 — dual-write only. Reads still
come from the plaintext columns and those columns stay populated. Real
protection needs P2 backfill → P3 read-from-`_enc` → P4 drop plaintext.

Phase 1 is enabled in PR #83. Sequencing, blockers and the backfill procedure:
`docs/homechef-pii-encryption-migration.md`.

### 1.2 `/metrics` and `/health/stats` internet-exposed — MEDIUM — fixed in PR #83

`api.fe3dr.com` routes `prefix: /` to the API, so the unauthenticated
Prometheus handler at `routes.go:211` was public. Verified live before the fix:

```
GET https://api.fe3dr.com/metrics       -> 200, 14302 bytes
GET https://api.fe3dr.com/health/stats  -> 200
```

Leaked the Go version (`go1.26.5`), goroutine/CPU/DB-pool shape, the full
internal API surface via per-path metric labels, and business volume counters
(`users_registered_total`, `chef_signups_total`, `order_value_dollars`). No PII
and no UUIDs in labels — paths are templated.

The comment at `routes.go:219` claiming only `/api` and `/ws` reach this service
is correct for `fe3dr.com` and **wrong for `api.fe3dr.com`**.

Fixed with a DENY AuthorizationPolicy at all four ingress gateways
(`charts/infrastructure/istio-auth-policies/templates/ops-endpoints-deny.yaml`).
It is driven by its own gateway list, **not** `ingressGateways` — attaching that
list's broad ALLOW policies to `homechef-ingressgateway` would turn every
unlisted path into a deny and take the site down.

### 1.3 Over-privileged service account — MEDIUM — fixed, applied live

`app-secrets-homechef-prod@` held project-level `roles/secretmanager.admin`.
That role includes `secretmanager.secrets.setIamPolicy`, so the API pod could
grant itself — or anyone — access to **every secret in the project, across all
products**. An RCE or SSRF in homechef-api escalated to the whole estate.

Not simply removable: the app legitimately creates, versions and deletes secrets
(per-vendor Razorpay credentials, DPDP deletion). A name-prefix IAM condition
also cannot work, because `secretmanager.secrets.create` is authorised against
the parent project, not the not-yet-existent secret.

Replaced with custom role `homechefSecretWriter`
(`docs/iam/homechef-secret-writer-role.yaml`) carrying exactly the four
operations the code performs, minus IAM mutation. Applied add-then-remove so
capability never lapsed; verified `/health` 200 and no permission errors after.

### 1.4 Hardcoded super-admin allowlist — MEDIUM — fixed in PR #83

`models/staff.go:321` hardcoded three personal Gmail addresses as the fallback
super-admin list, and `SUPER_ADMIN_EMAILS` was unset in prod.
`RequireStaffPermission` auto-provisions `StaffRoleSuperAdmin` for any caller
whose signed `X-User-Email` matches. Gated behind `RequirePool(internal)` +
`RequireAdmin`, so not directly exploitable — but control of one personal Gmail
in the internal realm equalled full platform admin.

Now sourced from `prod-homechef-admin-allowed-emails`. The secret's format was
verified before wiring: a malformed value produces a non-empty *garbage* list,
and the built-in fallback only engages on an **empty** parse — so a wrong format
would have locked every admin out rather than failing safe.

### 1.5 GCS — defense-in-depth gaps, not exposures — OPEN

Bucket separation is correct: identity documents live in `homechef-prod-docs-in`
(public access prevention **enforced**, not public), served via 15-minute signed
URLs with no object ACLs anywhere in the codebase. Public assets are a separate
bucket.

Two gaps remain:
- **`uniform_bucket_level_access` is `false` on every bucket**, including the
  identity-docs one. Per-object ACLs can therefore grant public read on an
  individual file, bypassing the bucket policy.
- **`tesseract-terraform-states` has `public_access_prevention: inherited`**,
  not enforced. Terraform state routinely contains plaintext secrets.

### 1.6 Mesh / network posture — OPEN, flagged not changed

- `homechef` runs mTLS **PERMISSIVE**; `mark8ly`, `mark8ly-uat` and `global` run
  **STRICT**. The PII-bearing product is the laxer one. Mitigated in depth by
  `default-deny-ingress` plus five ALLOW authorization policies. Not changed:
  flipping to STRICT risks the ambient/HBONE breakage pattern from 2026-04-12.
- All `redis-*` namespaces are mTLS **DISABLE**, including `redis-homechef`,
  which is the session store — session data crosses the pod network unencrypted.
- No NetworkPolicies at all in `external-secrets`, `cnpg-system`, `argocd*`,
  `kargo*`, `cert-manager` — the namespaces that broker credentials.
- `global` has contradictory policies: `default-mtls-permissive` is set to
  STRICT while `global-mtls` is PERMISSIVE.

### 1.7 Verified clean

- **Webhooks** (`services/razorpay.go`): signature verified before any
  processing, fails closed on missing secret, constant-time compare, and
  `VerifyPaymentSignature` binds the (order, payment) pair so a payment from a
  different order cannot settle this one. Replay dedup claims the event id
  *after* the signature check.
- **BFF auth** (`middleware/bff_auth.go`): identity headers are bound into the
  HMAC, so a signed request cannot be replayed with a swapped role or pool.
  No legacy identity-unbound fallback. Soft-deleted accounts are rejected via an
  `Unscoped()` lookup rather than silently missed.
- **No SQL injection.** The `ORDER BY` concatenation in `handlers/chefs.go:209`
  is switch-constrained to `ASC`/`DESC` with literal column names. mark8ly's one
  `fmt.Sprintf` into `nextval` (`order/number.go:48`) takes a typed `uuid.UUID`
  and a validated enum.
- **mark8ly tenant isolation holds.** Verified live — spoofed `X-Tenant-Id` /
  `X-User-Id` against three endpoints returned identical status codes to plain
  requests. Note the comment in `marketplace-api/internal/auth/middleware.go`
  credits Istio with stripping those headers; what actually holds is
  `MARKETPLACE_INTERNAL_AUTH_SECRET`, which is set on all three services.
- **No PII in logs** — identifiers only; the FCM token is truncated.
- **No hardcoded secrets** across 1,880 mark8ly Go files.
- **All secrets via `secretKeyRef`** / External Secrets.

---

## 2. Cost findings

Prices are asia-south1 list, approximate, and used for **relative** comparison.

### 2.1 Orphaned disks — the single largest waste

| Measure | Value |
|---|---|
| Unattached GCE PDs | **1552 GB** |
| PVs in `Released` phase | **31, totalling 1398Gi** |
| Live provisioned PVCs | 1511Gi across 69 bound PVs |
| Actually used | **~52Gi (~3.4%)** |

At pd-balanced rates that is roughly **$150-180/month for disks attached to
nothing**, on top of a similar amount for live volumes that are ~97% empty.

**The cause is structural.** `standard-rwo-retain` sets `reclaimPolicy: Retain`,
so when the autoheal CronJob destroys a wedged CNPG replica for the operator to
rebuild, that replica's data + WAL disks are stranded permanently.
`homechef-postgres` alone had ordinals 7 and 11-19 released while the live
cluster ran 20-22 — ten rebuild cycles at 130Gi each. **This leak grows with
every heal event.**

Fixed by making the weekly `Reclaim Orphan Storage` workflow actually reclaim
(see §3.1). The tooling already existed and was report-only, which is why
nothing was ever cleaned.

### 2.2 GCS lifecycle policies cost more than having none

Every bucket used the chain `Standard → Nearline@7d → Coldline@15d →
Archive@30d → Delete@90d`. GCS bills a **minimum storage duration** per class
regardless of when the object is deleted: Nearline 30d, Coldline 90d, Archive
365d. So each object was billed 30 days of Nearline for 8 days of use, 90 days
of Coldline for 15, and 365 days of Archive for 60.

| Policy (90-day retention) | ~$/GB |
|---|---|
| Old 4-tier chain | 0.069 |
| All Standard, no tiering | 0.069 |
| Standard → Nearline@7d | **0.041** |

The four-tier chain cost the same as never tiering at all.

**Rule:** only transition to a colder class if the object will live at least
that class's minimum duration. At ≤30-day retention, Coldline and Archive can
never pay off.

`devai-prod-logs-in` was the worst case — `Nearline@2d → Coldline@7d →
Delete@15d` billed 30 days of Nearline *and* 90 days of Coldline for objects
kept 15 days, roughly **3× the cost of no lifecycle at all**.

Applied (see §3.2). Full reasoning: `docs/gcs-backup-lifecycle/README.md`.

### 2.3 Already efficient — no action

- All 3 nodes are `e2-standard-8` **spot** instances.
- `gpu-l4-spot` and `sandbox-gvisor` node pools exist but run 0 nodes.
- Artifact Registry repositories are all remote/pull-through caches (~0 GB).
- 4 forwarding rules, 2 reserved internal IPs — negligible.

### 2.4 Open opportunity — right-size the over-provisioned volumes

1511Gi provisioned against ~52Gi used. `homechef-postgres` runs 3 × 100Gi data +
3 × 30Gi WAL (390Gi) at ~0% after the 2026-07-25 prod reset; `mark8ly-postgres`
is 200Gi at 0%.

PVCs cannot shrink in place, so this means recreating volumes — cheap **now**
while the databases are near-empty, expensive later. The volume autoscaler in
PR #83 is what makes this safe: growth becomes automatic, so provisioning small
stops being a risk.

---

## 3. Changes applied

### 3.1 Weekly orphan-storage reclamation — this PR

`.github/workflows/audit-orphan-storage.yml` scheduled runs now execute with
`--apply` and `age_days=7`, instead of report-only at 14 days.

Safe because `scripts/audit-orphan-storage.py` only ever auto-deletes two
categories — `RELEASED_PV` (PV phase Released, PVC already gone) and
`ZOMBIE_DISK` (a GCE disk with no matching PV) — and only when the disk is
currently unattached and has been detached at least `age_days`. Anything bound,
in use by a running pod, or an in-scope CNPG/StatefulSet member is classified
separately and never auto-deleted regardless of age.

The `Released` check runs *before* the CNPG-membership check, which is why the
stranded replica volumes in §2.1 are reclaimable while an in-flight rebuild
(still `Bound`, pod temporarily down) is protected.

Workflow-dispatch inputs were also moved behind `env:` rather than interpolated
into the shell body.

### 3.2 GCS lifecycle — applied live 2026-07-26

| Bucket | Change | Deletion impact |
|---|---|---|
| `tesseract-prod-backups-in` | Coldline + Archive removed → `Standard → Nearline@7d`; Delete kept at 90d | none |
| `devai-prod-logs-in` | all transitions removed, Delete@15d kept | none |
| `tesseracthub-480811-mark8ly-pg-backups` | Coldline + Archive removed | none |

### 3.3 IAM — applied live 2026-07-26

`roles/secretmanager.admin` → custom `homechefSecretWriter` on
`app-secrets-homechef-prod@`. See §1.3.

### 3.4 In PR #83 (not yet merged)

Volume autoscaler; 6-hourly CNPG base backups across 13 charts; homechef Barman
retention 90d → 30d; MongoDB 6-hourly + PBM point-in-time recovery;
ops-endpoint DENY; PII encryption phase 1; super-admin allowlist.

---

## 4. Deliberately not done

- **Bucket `Delete@37d`.** Would permanently remove 10,999 objects / 8.11GiB
  aged over 37 days. More importantly it is **blocked on PR #83**: live Barman
  retention for `homechef-postgres` is still 90d, so deleting at 37d would
  remove base backups and WAL that Barman's catalogue still references and
  silently break PITR — a failure that only surfaces during a restore. The
  bucket Delete rule must always stay longer than the engine retention.
- **`prod-volume-autoscaler-git-token`.** The autoscaler needs a fine-grained
  PAT (contents:write on `tesserix-k8s` only). The local `gh` token was **not**
  used — it carries `admin:org`, `delete_repo`, `repo` and `workflow`, and
  storing that for an unattended CronJob would be a larger risk than the one
  removed in §1.3. Must be minted in the GitHub UI.
- **Merging PR #83.** Blocked on CODEOWNERS review. Not overridden despite admin
  rights: a hardening change that bypasses branch protection to land itself
  defeats its own purpose.
- **`run-sources-*` retention.** Adding a delete rule to a bucket that has none
  is a policy decision, not a cleanup.
- **PII phases 2-4.** Strictly sequential — P2 needs P1 deployed, P3 needs P2
  finished or the two existing user rows (plaintext in `email_enc`, empty
  `email_bidx`) fail their blind-index login lookup.

---

## 5. Re-verification commands

```bash
# 1.2 — ops endpoints must NOT return 200 from outside
curl -s -o /dev/null -w '%{http_code}\n' https://api.fe3dr.com/metrics
curl -s -o /dev/null -w '%{http_code}\n' https://api.fe3dr.com/health/stats

# 1.3 — must NOT list roles/secretmanager.admin
gcloud projects get-iam-policy tesseracthub-480811 \
  --flatten="bindings[].members" \
  --filter="bindings.members:app-secrets-homechef-prod@tesseracthub-480811.iam.gserviceaccount.com" \
  --format="value(bindings.role)"

# 2.1 — orphan disk total should trend to ~0 after the weekly sweep
gcloud compute disks list --project=tesseracthub-480811 --filter="-users:*" \
  --format="value(sizeGb)" | paste -sd+ - | bc
kubectl get pv -o json | jq '[.items[]|select(.status.phase=="Released")]|length'

# 2.2 — no COLDLINE/ARCHIVE transitions should remain on backup buckets
for b in tesseract-prod-backups-in devai-prod-logs-in \
         tesseracthub-480811-mark8ly-pg-backups; do
  echo "== $b"
  gcloud storage buckets describe gs://$b --project=tesseracthub-480811 \
    --format="json(lifecycle_config)" | jq -c '.lifecycle_config.rule[]?.action'
done

# 2.4 — provisioned vs used
kubectl get pvc -A -o json | jq '[.items[].spec.resources.requests.storage
  |rtrimstr("Gi")|tonumber? // 0]|add'
```
