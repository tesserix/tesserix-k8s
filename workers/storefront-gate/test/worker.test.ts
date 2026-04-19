import { describe, it, expect, vi, beforeEach } from "vitest";
import { SELF } from "cloudflare:test";
import { decide } from "../src/index";

// mockOrigin replaces the global fetch with a function that returns the
// canned status payload for /internal/storefront-status/* and a sentinel
// "ORIGIN" body for any other URL (the pass-through case).
function mockOrigin(payload: unknown, status = 200) {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const url = typeof input === "string" ? input : (input as Request).url;
    if (url.includes("/internal/storefront-status/")) {
      return new Response(payload ? JSON.stringify(payload) : null, { status });
    }
    return new Response("ORIGIN", { status: 200 });
  });
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("decide", () => {
  it("returns pass_through for null payload (fail-open)", () => {
    expect(decide(null)).toBe("pass_through");
  });

  it.each([
    ["signup"],
    ["trialing"],
    ["active"],
    ["past_due"],
    ["payment_action_required"],
    ["cancel_scheduled"],
    ["expired"],
  ])("passes through %s", (status) => {
    expect(
      decide({
        status: status as never,
        plan: "starter",
        branding: { name: "x", logo_url: "", support_email: "" },
      }),
    ).toBe("pass_through");
  });

  it.each([["store_closed"], ["pending_hard_delete"]])(
    "serves closed for %s",
    (status) => {
      expect(
        decide({
          status: status as never,
          plan: "starter",
          branding: { name: "x", logo_url: "", support_email: "" },
        }),
      ).toBe("serve_closed");
    },
  );

  it("serves 404 for hard_deleted", () => {
    expect(
      decide({
        status: "hard_deleted",
        plan: "starter",
        branding: { name: "x", logo_url: "", support_email: "" },
      }),
    ).toBe("serve_404");
  });
});

describe("storefront-gate Worker", () => {
  it("serves closed.html with 200 + noindex for store_closed", async () => {
    mockOrigin({
      status: "store_closed",
      plan: "starter",
      branding: { name: "Acme", logo_url: "", support_email: "x@y.com" },
    });
    const res = await SELF.fetch("https://acme.mark8ly.com/");
    expect(res.status).toBe(200);
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
    expect(res.headers.get("Content-Type")).toContain("text/html");
    expect(res.headers.get("Mark8ly-Closed-Store")).toBe("true");
    expect(res.headers.get("Cache-Control")).toBe("public, max-age=300");

    const body = await res.text();
    expect(body).toContain("Acme");
    expect(body).toContain("This store is currently closed.");
  });

  it("serves closed.html for pending_hard_delete", async () => {
    mockOrigin({
      status: "pending_hard_delete",
      plan: "starter",
      branding: { name: "Zephyr", logo_url: "", support_email: "z@y.com" },
    });
    const res = await SELF.fetch("https://zephyr.mark8ly.com/");
    expect(res.status).toBe(200);
    expect(res.headers.get("Mark8ly-Closed-Store")).toBe("true");
  });

  it("serves 404 for hard_deleted", async () => {
    mockOrigin({
      status: "hard_deleted",
      plan: "starter",
      branding: { name: "Gone", logo_url: "", support_email: "" },
    });
    const res = await SELF.fetch("https://gone.mark8ly.com/");
    expect(res.status).toBe(404);
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
  });

  it("passes through to origin for expired (grace window)", async () => {
    mockOrigin({
      status: "expired",
      plan: "starter",
      branding: { name: "Grace", logo_url: "", support_email: "g@y.com" },
    });
    const res = await SELF.fetch("https://grace.mark8ly.com/products/widget");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ORIGIN");
    expect(res.headers.get("Mark8ly-Closed-Store")).toBeNull();
  });

  it("passes through for active stores", async () => {
    mockOrigin({
      status: "active",
      plan: "starter",
      branding: { name: "Live", logo_url: "", support_email: "l@y.com" },
    });
    const res = await SELF.fetch("https://live.mark8ly.com/");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ORIGIN");
  });

  it("fails open on origin 5xx (passes through)", async () => {
    mockOrigin(null, 503);
    const res = await SELF.fetch("https://flaky.mark8ly.com/");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ORIGIN");
  });

  it("fails open on origin 404 (unknown host → pass-through)", async () => {
    mockOrigin(null, 404);
    const res = await SELF.fetch("https://ghost.mark8ly.com/");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ORIGIN");
  });

  it("escapes store name in rendered HTML", async () => {
    mockOrigin({
      status: "store_closed",
      plan: "starter",
      branding: {
        name: `<script>alert(1)</script>`,
        logo_url: "",
        support_email: "x@y.com",
      },
    });
    const res = await SELF.fetch("https://xss.mark8ly.com/");
    const body = await res.text();
    expect(body).not.toContain("<script>alert(1)</script>");
    expect(body).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
  });
});
