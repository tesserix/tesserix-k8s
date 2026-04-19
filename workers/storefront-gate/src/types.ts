// Subscription state mirror — must stay in sync with marketplace-api's
// SubscriptionStatus enum (services/marketplace-api/internal/subscription/models.go).
export type StorefrontStatus =
  | "signup"
  | "trialing"
  | "active"
  | "past_due"
  | "payment_action_required"
  | "cancel_scheduled"
  | "expired"
  | "store_closed"
  | "pending_hard_delete"
  | "hard_deleted";

export interface Branding {
  name: string;
  logo_url: string;
  support_email: string;
}

// Mirror of internalsvc.StorefrontStatusResponse.
export interface StorefrontStatusPayload {
  status: StorefrontStatus;
  plan: string;
  branding: Branding;
  current_period_end?: string | null;
}

// Worker bindings declared in wrangler.toml.
export interface Env {
  STATUS_KV: KVNamespace;
  INTERNAL_API_BASE: string;
  // Injected as a Wrangler secret; never commit a real value.
  INTERNAL_API_TOKEN: string;
  STATUS_CACHE_TTL_SECONDS: string;
  CLOSED_PAGE_ANALYTICS?: AnalyticsEngineDataset;
}
