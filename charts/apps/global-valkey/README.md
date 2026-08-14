# global-valkey

Shared Valkey for all products, replacing the per-product `redis-*` instances.
Two instances, following the `global-postgres` convention in the `global`
namespace.

| Instance | Eviction | AOF | Consumers |
|---|---|---|---|
| `global-valkey-cache` | `allkeys-lru` | off | devai, homechef, marketplace, tesserix |
| `global-valkey-queue` | `noeviction` | on | openpanel, postiz |

They are split because the two workloads need opposite policies: an LRU that
protects cache hit rate would silently evict queued jobs, and a `noeviction`
cache would start returning OOM errors instead of just missing.

## Topology

Each instance is 1 primary + 2 replicas with a co-located Sentinel on every
pod, plus a 2-replica HAProxy.

Three nodes rather than two is a quorum requirement, not redundancy for its own
sake: Sentinel needs a majority to promote, so a 2-member set that loses one
member can never fail over and the "replica" buys durability without
availability.

HAProxy exists for clients that only speak `redis://host:6379`. Its health
check accepts a backend only when `INFO replication` reports `role:master`, so
a Sentinel promotion moves traffic with no client-side awareness. Sentinel-aware
clients may instead talk to `<instance>-sentinel:26379` directly.

## Connecting

```
# Any client — always resolves to the current primary.
redis://global-valkey-cache.global.svc.cluster.local:6379

# With an ACL user (cache instance), confining the client to its own prefix.
redis://homechef@global-valkey-cache.global.svc.cluster.local:6379
```

## Auth

There is no password. Access control is two layers:

1. **NetworkPolicy** — only namespaces listed in `networkPolicy.allowedNamespaces`
   can reach the ports. This is the real boundary.
2. **ACL users** — each consumer gets a `nopass` user restricted to its own key
   prefix (`~homechef:*`), so a shared instance still isolates products from
   each other. `nopass` accepts any password, which is what lets replication and
   Sentinel authenticate without a stored secret.

The queue instance runs with `acl.enabled: false` because openpanel and postiz
are third-party apps whose Redis client is not configurable beyond `REDIS_URL`.

## Noisy neighbours

`maxmemory` and the LRU are instance-wide, so one product filling the cache
evicts another's keys. Key prefixes isolate access, not capacity. If a consumer
ever needs a guaranteed working set, give it its own instance from this same
chart rather than raising the shared limit.

## Verifying failover

```bash
kubectl -n global exec global-valkey-cache-0 -c valkey -- \
  valkey-cli --user healthcheck --pass x info replication | grep role

kubectl -n global delete pod global-valkey-cache-0   # whichever is primary

kubectl -n global exec global-valkey-cache-1 -c sentinel -- \
  valkey-cli -p 26379 sentinel get-master-addr-by-name global-valkey-cache
```

The HAProxy-fronted Service should keep serving throughout.
