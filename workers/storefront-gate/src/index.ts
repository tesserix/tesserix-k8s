import type { Env, StorefrontStatus, StorefrontStatusPayload } from "./types";
import { fetchStorefrontStatus } from "./status";
import { render } from "./interpolate";
// closed.html is bundled as a string by Wrangler's "Text" rule (see wrangler.toml).
import CLOSED_HTML from "./closed.html";

const RETURN_URL = "https://mark8ly.com";

const CLOSED_STATES: ReadonlySet<StorefrontStatus> = new Set([
  "store_closed",
  "pending_hard_delete",
]);

export type Decision = "serve_closed" | "serve_404" | "pass_through";

// decide is the pure routing predicate. Extracted so tests can hammer the
// state matrix without spinning up Miniflare.
export function decide(payload: StorefrontStatusPayload | null): Decision {
  if (!payload) return "pass_through"; // unknown host or fail-open
  if (payload.status === "hard_deleted") return "serve_404";
  if (CLOSED_STATES.has(payload.status)) return "serve_closed";
  return "pass_through";
}

function closedResponse(html: string): Response {
  return new Response(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "X-Robots-Tag": "noindex",
      "Cache-Control": "public, max-age=300",
      "Mark8ly-Closed-Store": "true",
    },
  });
}

function notFoundResponse(): Response {
  return new Response("Not Found", {
    status: 404,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "X-Robots-Tag": "noindex",
      "Cache-Control": "public, max-age=300",
    },
  });
}

function renderClosed(payload: StorefrontStatusPayload): string {
  return render(CLOSED_HTML as unknown as string, {
    STORE_NAME: payload.branding.name,
    LOGO_URL: payload.branding.logo_url,
    SUPPORT_EMAIL: payload.branding.support_email,
    RETURN_URL,
  });
}

// logClosedRender is best-effort. AnalyticsEngineDataset.writeDataPoint
// can throw on quota exhaustion; we swallow because losing one data point
// must not kill the response.
function logClosedRender(env: Env, host: string, status: StorefrontStatus): void {
  if (!env.CLOSED_PAGE_ANALYTICS) return;
  try {
    env.CLOSED_PAGE_ANALYTICS.writeDataPoint({
      blobs: [host, status],
      doubles: [1],
      indexes: [host],
    });
  } catch {
    /* analytics is best-effort */
  }
}

export default {
  async fetch(
    request: Request,
    env: Env,
    _ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);
    const host = url.hostname;

    const payload = await fetchStorefrontStatus(env, host);
    const decision = decide(payload);

    if (decision === "serve_404") {
      logClosedRender(env, host, "hard_deleted");
      return notFoundResponse();
    }
    if (decision === "serve_closed" && payload) {
      logClosedRender(env, host, payload.status);
      return closedResponse(renderClosed(payload));
    }
    // pass_through: forward to origin unchanged.
    return fetch(request);
  },
};
