# Supplier current-source verification

Candidate GitOps rollout: both `helivanta-api` and `helivanta-global-api` must enable
`supplierTrade.enabled`. Defaults remain disabled. The deployed application already
supports this protocol; absence of configuration returns unavailable and prevents
regulated trading. No new service, credentials or data master is introduced.

The owner calls its cluster-local service's exact POST path
`/v1/supply/internal/trading-source/check`. Istio STRICT mTLS and the owner boundary
admit only `helivanta-api`'s service-account principal. A dedicated audience
`helivanta-supplier-trade-current` token rotates every 600 seconds. The application
validates it through Kubernetes TokenReview against that audience and exact account;
existing workload-identity chart RBAC permits only creating TokenReviews. Tokens
remain mounted read-only and are never written to Helm values. This reuses the
existing three-second application deadline, with no proxy retry added.

The new app-owned network policy admits API pods of the same release/component on
8080 and control-plane 172.16.0.2/32 on 443. That control-plane endpoint was verified
read-only on 2026-11-09. Existing clinical verification independently retains its
configuration. Standard Kubernetes API credentials are projected once if either
verifier is enabled. Non-peer business routes still require Global API. Enabling
this transport does not grant users stock authority, approve licences, activate a
trading policy or create a bilateral relationship.

No new replicas, storage or external services are required. Extra work is one
bounded TokenReview and owner read for each source verification; existing API
availability/latency monitoring applies. Verify an authenticated peer response and
rejection of Global API/user callers after rollout. Positive regulated dispatch
still requires genuine reviewed source licences, state/category policies, scopes
and a bilateral relationship. Record those separately from transport readiness.

Rollback by reverting both production `supplierTrade` settings through GitOps;
this restores fail-closed unavailable behavior without altering stock or financial
history. Do not remove TokenReview RBAC: clinical verification also owns its use.
