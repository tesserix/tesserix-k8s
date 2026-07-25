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
object deleted at d30 that reached Archive is billed for a full year.

## Current policy (30-day recovery window)

```
Standard -> NEARLINE @7d -> Delete @37d
```

≈ **$0.018/GB**, and Nearline retrieval is $0.01/GB versus Archive's $0.05/GB,
so restores are cheaper too — which matters precisely when you are already
having a bad day.

The 0–7d Standard window is deliberate: that is the range you actually restore
from, and Standard has no retrieval fee.

## The 37 vs 30 day gap is load-bearing

Barman (CNPG) and PBM (MongoDB) are **chain-aware** pruners — they delete a base
backup together with the WAL segments or oplog slices that depend on it, so
point-in-time recovery is never left with a hole. Both are set to a 30-day
window.

The bucket's `Delete @37d` is a **backstop for orphans only**. It must stay
strictly longer than the engine retention. If GCS deleted an object the Barman
catalogue still referenced, PITR would fail at restore time with no prior
warning — the failure only surfaces when you need it.

**Never set the bucket Delete rule to less than the engine retention.**

## Applying it

> **This is destructive.** Measured 2026-07-26: the bucket held 38,426 objects
> / 11.24GiB, of which **10,999 objects (8.11GiB) were older than 37 days** and
> are permanently deleted the first time the new rule runs. Most were
> stockpilot base backups. Confirm that is acceptable before applying.

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
