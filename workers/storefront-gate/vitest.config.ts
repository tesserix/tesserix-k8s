import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

// Vitest + Miniflare: every test runs inside a real Workers isolate so we
// exercise the same KV / fetch / Analytics Engine bindings the Worker uses
// in production.
export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          // Provide the secret bindings inline; never commit real secrets.
          bindings: {
            INTERNAL_API_TOKEN: "test-token",
          },
        },
      },
    },
  },
});
