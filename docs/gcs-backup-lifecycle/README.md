# Backup bucket lifecycle — `gs://tesseract-prod-backups-in`

## Why the old policy cost more than doing nothing

The previous lifecycle was:

```
Standard -> NEARLINE @7d -> COLDLINE @15d -> ARCHIVE @30d -> Delete @90d
```

Every one of those transitions triggered a **minimum-storage-duration charge**.
GCS bills a minimum per class no matter when the object is actually deleted:

| Class    | Minimum duration |
|----------|------------------|
| Standard | none             |
| Nearline | 30 days          |
| Coldline | 90 days          |
| Archive  | 365 days         |

So under the old policy every object:

- entered Nearline at d7 and left at d15 — **8 days used, 30 billed**
- entered Coldline at d15 and left at d30 — **15 days used, 90 billed**
- entered Archive at d30 and was deleted at d90 — **60 days used, 365 billed**

Cost per GB over a 90-day life (asia-south1, approximate list prices):

| Policy                                   | ~$/GB  |
|------------------------------------------|--------|
| Old: Std -> NL -> CL -> Archive, del@90d | 0.069  |
| All Standard, delete @90d                | 0.069  |
| Std -> Nearline @7d, delete @90d         | 0.041  |

The four-tier chain cost the same as never tiering at all, because the cold
tiers were never held long enough to pay for themselves.

## The rule to apply

> Only transition an object to a colder class if it will live **at least that
> class's minimum duration**.

At a 30-day retention that means Coldline and Archive can never pay off — an
object deleted at d30 that reached Archive is billed for a full year. At the
3-day Postgres retention below, **no** tiering pays off, which is why the
Nearline transition is scoped away from the Postgres prefixes.

## Current policy

The bucket has two classes of tenant with different retention, so the rules are
prefix-scoped rather than bucket-wide.

| Prefixes | Engine retention | Lifecycle |
|---|---|---|
| `*-postgres/` (CNPG) | 3 days — one daily base backup, latest 3 kept | Standard, `Delete @10d` |
| `openbao/`, `homechef-mongodb/` | 30 days | `Standard -> NEARLINE @7d -> Delete @37d` |
| `qdrant/` | 14 days | Standard, `Delete @37d` |

Postgres objects never leave Standard: they live at most 10 days and Nearline
bills a 30-day minimum, so tiering them is a pure loss. Standard also has no
retrieval fee, which is what you want for the window you actually restore from.

## The backstop gap is load-bearing

Barman (CNPG) and PBM (MongoDB) are **chain-aware** pruners — they delete a base
backup together with the WAL segments or oplog slices that depend on it, so
point-in-time recovery is never left with a hole.

Every bucket `Delete` rule is a **backstop for orphans only**, and each must stay
strictly longer than the engine retention it covers — 10d against a 3-day Barman
window, 37d against a 30-day one. If GCS deleted an object the Barman catalogue
still referenced, PITR would fail at restore time with no prior warning; the
failure only surfaces when you need it.

**Never set a bucket Delete rule to less than the engine retention under it**,
and when adding a new CNPG cluster, add its prefix to the 10-day rule — without
it the cluster falls through to the 37-day rule and quietly keeps a month of
backups nobody costed for.

## Applying it

> **This is destructive.** The 10-day Postgres rule permanently deletes every
> base backup and WAL segment older than 10 days across all `*-postgres/`
> prefixes the first time it runs — roughly 27 of the 30 days currently held.
> Apply it only after the charts in this repo are on `retentionPolicy: "3d"`,
> so Barman has already pruned its own catalogue to match; applying it first
> leaves the catalogue referencing objects GCS has removed.

```bash
gcloud storage buckets update gs://tesseract-prod-backups-in \
  --lifecycle-file=docs/gcs-backup-lifecycle/tesseract-prod-backups-in-lifecycle.json \
  --project=tesseracthub-480811

# verify
gcloud storage buckets describe gs://tesseract-prod-backups-in \
  --format="json(lifecycle_config)" --project=tesseracthub-480811
```

Objects already sitting in Coldline or Archive stay there — GCS lifecycle can
only move an object to a colder class, never back. Their minimums are already
sunk; the new policy only prevents future objects from repeating it.

## A note on scale

At 11.24GiB total, the difference between the old and new policy is well under
$1/month. The reason to change it is **correctness as the data grows**, not
present savings — the old policy's cost penalty scales linearly with volume, and
HomeChef's Postgres is near-empty today only because prod was reset for launch
on 2026-07-25. Do not treat this as an urgent cost fix; treat it as removing a
trap that gets more expensive every month.
