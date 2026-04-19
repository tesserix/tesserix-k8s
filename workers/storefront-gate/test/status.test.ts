import { describe, it, expect, vi, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { fetchStorefrontStatus, cacheKey } from "../src/status";

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("fetchStorefrontStatus", () => {
  it("hits origin on cache miss, writes KV, returns payload", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          status: "store_closed",
          plan: "starter",
          branding: { name: "Acme", logo_url: "", support_email: "x@y.com" },
        }),
        { status: 200 },
      ),
    );

    const out = await fetchStorefrontStatus(env, "acme.mark8ly.com");
    expect(out?.status).toBe("store_closed");
    expect(fetchSpy).toHaveBeenCalledOnce();

    // Allow the fire-and-forget KV write to settle, then a second call
    // should be served from KV without a second origin fetch.
    await new Promise((r) => setTimeout(r, 10));
    const out2 = await fetchStorefrontStatus(env, "acme.mark8ly.com");
    expect(out2?.status).toBe("store_closed");
    expect(fetchSpy).toHaveBeenCalledOnce();
  });

  it("returns null on origin 404 (unknown host)", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(null, { status: 404 }),
    );
    const out = await fetchStorefrontStatus(env, "ghost.mark8ly.com");
    expect(out).toBeNull();
  });

  it("fails open on origin 5xx", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(null, { status: 503 }),
    );
    const out = await fetchStorefrontStatus(env, "flaky.mark8ly.com");
    expect(out).toBeNull();
  });

  it("fails open on fetch throw (DNS / network)", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(new Error("network"));
    const out = await fetchStorefrontStatus(env, "broken.mark8ly.com");
    expect(out).toBeNull();
  });

  it("fails open on JSON parse error", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response("not json", { status: 200 }),
    );
    const out = await fetchStorefrontStatus(env, "weird.mark8ly.com");
    expect(out).toBeNull();
  });

  it("URL-encodes the host parameter", async () => {
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(new Response(null, { status: 404 }));
    await fetchStorefrontStatus(env, "weird host.mark8ly.com");
    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining("weird%20host.mark8ly.com"),
      expect.any(Object),
    );
  });
});

describe("cacheKey", () => {
  it("prefixes host with status:", () => {
    expect(cacheKey("acme.mark8ly.com")).toBe("status:acme.mark8ly.com");
  });
});
