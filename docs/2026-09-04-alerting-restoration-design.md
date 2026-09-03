# Alerting restoration — design

**Status:** proposed
**Date:** 2026-09-04
**Related:** `docs/observability-park.md`, mark8ly#624, tesserix-k8s#899

## Problem

The estate has no working alerting, and has not had for longer than the August park suggests.

```
PrometheusRule CRs in cluster     : 16   (7 products: Postgres, OpenFGA, agent lifecycle)
prometheus-operator pods          : 0    ← only the CRD chart was ever installed
Rule groups loaded in Prometheus  : 0
Alert rules in the chart's values : none
Alertmanager replicas             : 0
Alertmanager receivers configured : none
```

Two independent faults compound:

1. **Nothing evaluates the rules.** The 16 `PrometheusRule` CRs are authored for prometheus-operator. The running Prometheus is the *community* chart (`prometheus 25.30.2`), which reads rules from its own config and ignores CRs entirely. The `prometheus-operator-crds` ArgoCD app installs the CRDs but no operator, so the CRs are inert objects.
2. **Nothing delivers them.** Alertmanager is at 0 replicas (parked 2026-08-01 for cost) and no receiver is configured anywhere, so even a running alertmanager would fire into a void.

`docs/observability-park.md` says alerts do not fire "while Prometheus and Alertmanager are at 0", implying that reviving Prometheus restores evaluation. **It does not.** Prometheus was revived on 2026-09-03 (tesserix-k8s#899) and loads zero rules, because nothing connects the CRs to it.

This includes `global-postgres-alerts` and the CNPG disk-full rules the park doc specifically flags: *"a repeat of the 2026-06-17 Postgres disk deadlock would arrive with no warning."* That is true today and would remain true if alertmanager were un-parked tomorrow.

It also means deploy failures surface only by accident. On 2026-09-03 a sigstore TUF 403 failed image signing on `main`, no Freight formed, and migration 000129 sat undeployed — found only because someone was watching main CI by hand.

## Goal

Alerts that evaluate, route, and arrive somewhere a human reads — starting with the conditions that have already caused incidents.

## Approach: install kube-prometheus-stack alongside, then cut over

### Why not swap in place

kube-prometheus-stack discovers targets through `ServiceMonitor`/`PodMonitor` CRs and does **not** scrape `prometheus.io/*` pod annotations by default.

The community chart's annotation-based `kubernetes-pods` job is currently the only thing scraping marketplace-api — `http_requests_total`, `carriersecrets_events_total`, and the rest of the metrics restored in mark8ly#625/#635 and tesserix-k8s#899. A straight replacement drops them silently.

**And we would have no alerting to notice.** The safe shape follows from that: do the migration in a way that does not depend on the monitoring it is repairing.

### Phases

**Phase 1 — stand up the stack, deliver nothing.**
Install `kube-prometheus-stack` into `monitoring` with alerting routed to a null receiver. The operator begins evaluating all 16 `PrometheusRule` CRs. Nothing is delivered yet, so a noisy or wrong rule costs nothing.

Carry the community chart's scrape config forward via `prometheus.prometheusSpec.additionalScrapeConfigs`:
- the annotation-based `kubernetes-pods` job (marketplace-api depends on it)
- the four Istio jobs (`istio-proxy`, `istiod`, `istio-ingressgateway`, `istio-egressgateway`)

**Phase 2 — prove parity before trusting it.**
The new Prometheus must scrape everything the old one does. Concretely: `count({job="kubernetes-pods"})` and the marketplace-api series (`http_requests_total`, `carriersecrets_events_total`) must be present and non-zero in the new instance, and the Istio jobs must show targets `up`. Compare `/api/v1/targets` between the two instances and diff the job list.

Do not proceed until this passes. This is the phase that protects the metrics we just restored.

**Phase 3 — route criticals to Slack.**
Add an alertmanager receiver using the estate's existing pattern: a webhook pulled through External Secrets, as `external-secrets/prod/argocd/notifications.yaml` and `external-secrets/prod/falco/falcosidekick-slack.yaml` already do.

Route `severity=critical` only; drop `warning` initially. The 16 rule sets have never fired in anger, so their thresholds are unproven — starting with criticals means the first alerts to arrive are ones worth acting on. A flood on day one is how a new channel gets muted permanently. Loosen per-rule as each earns trust.

**Phase 4 — add the alert that would have caught the sigstore failure.**
A promotion-failure alert. Kargo currently exposes no scraped metrics (no `prometheus.io/*` annotations, no metrics Service), so this needs either its controller metrics exposed and scraped, or an alert derived from images/Freight going stale. Scope this phase separately once the stack is proven — it is the motivating case, not the foundation.

**Phase 5 — retire the community chart.**
Once the stack is authoritative, scale the community `prometheus` release down and remove it, keeping `docs/observability-park.md` accurate about what remains parked.

## Cost

Measured 2026-09-04: the running Prometheus uses **3.4 GiB** (against a 2 GiB request and no limit). Nodes sit at 25–59% memory, with roughly 22 GiB free on the least loaded.

- Phase 1–4 run **two** Prometheus instances, ≈7 GiB combined. It fits, but it is the peak and should not be left running longer than parity verification needs.
- The stack adds alertmanager (small), and optionally `node-exporter` (DaemonSet, one pod per node) and `kube-state-metrics`. Both are currently parked at 0 in the community chart; enable them only if a rule needs them — several CNPG rules likely do, which Phase 2 will reveal.
- Grafana: **out of scope**. The stack bundles it; disable it. A parked Grafana already exists and dashboards are a separate decision.
- No new node pool. The `observability` pool deleted in the August park stays deleted — nothing here is scheduled onto it.

## Risks

| Risk | Mitigation |
|---|---|
| Losing annotation-based scraping — marketplace-api metrics vanish | Phase 2 gate; the old instance keeps running until parity is proven |
| 16 unproven rule sets flood the channel | Phase 1 delivers nothing; Phase 3 routes criticals only |
| Two Prometheis exhaust node memory | ~7 GiB against ~22 GiB free; coexistence is time-boxed to Phase 2 |
| Rules reference metrics nothing scrapes (e.g. kube-state-metrics series) | Phase 2 surfaces them as rules that never evaluate; enable exporters only where a rule needs them |
| Alerting for six products we do not own starts paging | Criticals only, and per-product routing is a follow-up conversation with those owners |

## Rollback

Each phase is independently reversible. Phases 1–2 add resources without touching the running Prometheus, so rollback is deleting the new release. Phase 3 is a receiver config change. Only Phase 5 is destructive, and only after the stack has been authoritative.

## Out of scope

- Grafana and dashboards
- Tuning the 16 existing rule sets — they are adopted as written; tuning follows evidence
- Long-term metric retention (the current instance is `emptyDir`; history dies on restart)
- Per-product alert ownership and escalation policy

## Open questions

1. Which Slack channel receives criticals, and who provides the webhook through the secret store?
2. Do the other six products' owners want their alerts routed now, or should Phase 3 start mark8ly-only?
3. Should Phase 5 retire the community chart, or keep it as a fallback scraper for one cycle?
