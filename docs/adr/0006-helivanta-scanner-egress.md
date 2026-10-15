# ADR 0006: Restrict private-document scanner egress

- Status: Accepted
- Date: 2026-10-15
- Scope: Helivanta document scanner only

## Context

The scanner processes confidential tenant files supplied by authenticated users.
A malicious file could exploit a scanner dependency; the trust boundary is the
scanner pod, which must not gain arbitrary Internet access to export those files.
The existing NetworkPolicy permits DNS, Istiod and public HTTPS for signature
updates. Public CDN addresses change, so a static IP allowlist is unsuitable.

This change adds no upload traffic, storage or replicas. The existing scanner
accepts bounded streams of at most 10 MiB, with one replica and current-definition
checks. Production throughput, growth and processing-latency SLOs remain to be
measured; this restriction does not assert new capacity or availability targets.

## Decision

Opt the scanner into the existing Istio proxy using the cluster's pod-label
selector. Add a namespace-local ServiceEntry for `database.clamav.net` on TLS
port 443 and a scanner-selected Sidecar with `REGISTRY_ONLY` outbound traffic.
Its egress registry contains only that mirror. Keep the existing NetworkPolicy,
mesh authentication and workload authorization. No other workload's egress changes.

This is a layered hostname restriction, not content inspection of encrypted
outbound traffic or a guarantee against a compromised privileged network stack.
The container remains non-root without network administration capabilities.

## Alternatives

Leaving public HTTPS unrestricted unnecessarily exposes an exfiltration path.
Pinning dynamic CDN IPs is brittle. A dedicated egress gateway would add a shared
failure domain and operational cost; it is not required for this scoped control.

## Failure behavior and consequences

Mirror or DNS failure prevents updates. Scans fail closed once definitions exceed
the application's 24-hour freshness limit; files are not released on an unknown,
encrypted or scan-limit verdict. Istiod failure prevents newly injected pods from
becoming ready; existing proxies retain their last accepted configuration.
No new pods, public addresses, storage or fixed cloud charges are introduced.

## Rollout and rollback

Keep upload acceptance false until the new proxy configuration is reconciled,
the mirror succeeds, unrelated HTTPS is blocked, workers poll Temporal and real
synthetic clean/antivirus/encrypted/over-limit scans pass. Then enable acceptance
in a separate GitOps change and test the full UI flow. Reverting this restriction
also uses GitOps; keep acceptance disabled during any unverified rollback.
