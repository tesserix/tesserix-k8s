import type { Env, StorefrontStatusPayload } from "./types";

const KEY_PREFIX = "status:";
const DEFAULT_TTL_SECONDS = 900;

// fetchStorefrontStatus is the hot-path lookup the Worker calls on every
// request. KV cache hit short-circuits the origin call; misses fetch the
// internal endpoint and write back to KV. Failure modes (origin 5xx, fetch
// throw, JSON parse error) all return null so the Worker treats them as
// pass-through (fail-open per §18.4 — never take a live store down for an
// edge-check failure).
export async function fetchStorefrontStatus(
  env: Env,
  host: string,
): Promise<StorefrontStatusPayload | null> {
  const key = cacheKey(host);

  const cached = await env.STATUS_KV.get<StorefrontStatusPayload>(key, "json");
  if (cached) return cached;

  const url = `${env.INTERNAL_API_BASE}/internal/storefront-status/${encodeURIComponent(host)}`;

  let res: Response;
  try {
    res = await fetch(url, {
      headers: {
        // Internal-auth shared secret. The marketplace-api handler matches
        // the X-Internal-Auth header; we send the same value to keep the
        // contract single-token.
        "X-Internal-Auth": env.INTERNAL_API_TOKEN,
        Authorization: `Bearer ${env.INTERNAL_API_TOKEN}`,
      },
      // Bypass Cloudflare cache — KV is our cache layer.
      cf: { cacheTtl: 0 },
    });
  } catch {
    return null;
  }

  if (res.status === 404) return null;
  if (!res.ok) return null;

  let payload: StorefrontStatusPayload;
  try {
    payload = (await res.json()) as StorefrontStatusPayload;
  } catch {
    return null;
  }

  // Fire-and-forget KV write; never block the response on cache persistence.
  const ttl = parseTTL(env.STATUS_CACHE_TTL_SECONDS);
  env.STATUS_KV.put(key, JSON.stringify(payload), { expirationTtl: ttl }).catch(
    () => {
      /* swallow — KV is best-effort */
    },
  );
  return payload;
}

// cacheKey is exported so a future cache-invalidation endpoint (P11
// reactivation) can DELETE the same key the read path looks up.
export function cacheKey(host: string): string {
  return `${KEY_PREFIX}${host}`;
}

function parseTTL(raw: string | undefined): number {
  if (!raw) return DEFAULT_TTL_SECONDS;
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 60) return DEFAULT_TTL_SECONDS;
  return n;
}
