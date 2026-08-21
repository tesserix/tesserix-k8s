# AI usage ledger — how the console's cost page fills

`console.tesserix.app/platform/ai-usage` reads one table, `ai_usage_events` in
`tesserix_admin`. Nothing else writes it. The chain is:

```
agentgateway (kora-ai, ai-gateway)
  → OTLP/HTTP spans → ai-usage-ingest:4318 /v1/traces   (tesserix namespace)
  → JetStream (nats)
  → ai_usage_events / ai_usage_hourly
  → platform-api /v1/platform/ai-usage/*
  → console
```

Every hop fails silently. A gateway with no `frontend.tracing` policy, a missing
NetworkPolicy egress rule or an absent ReferenceGrant all leave a healthy
gateway, a healthy ingest, and a page that says "no AI traffic reached the
gateway" — which is a claim about the estate, not about the wiring.

## Who owns which hop

| Hop | Owner | Where to change it |
|---|---|---|
| `AgentgatewayPolicy` `*-ai-observability` (the `tracing` block) | **Agentic Registry** since the 2026-08-19 handoff | `PUT /v0/agentgateway/policies/<name>` — see below |
| Gateway `NetworkPolicy` egress to the ingest | Helm | `charts/apps/{kora,devai}-ai-gateway/templates/networkpolicy.yaml` |
| Ingest Service, ReferenceGrant, ingress NetworkPolicy | Helm | `charts/apps/ai-usage-ingest` |
| Fallback rate card | operators | `ai_model_prices` rows in `tesserix_admin` |

The policy templates in the two gateway charts are the **rollback rendering**
described in ADR-0003, gated behind `registryOwnership.enabled=false`. Editing
them changes nothing in production on its own: Argo no longer applies those CRs.
Keep them in step with the Registry anyway, because the rollback path restores
exactly what they render.

## Updating a gateway's tracing policy

```bash
helm template x charts/apps/kora-ai-gateway -n agentgateway-system \
  --set registryOwnership.enabled=false \
  | yq 'select(.kind == "AgentgatewayPolicy" and .metadata.name == "kora-ai-observability")' -o json \
  > kora-ai-observability.json

curl --fail-with-body -X PUT \
  -H "Authorization: Bearer ${REGISTRY_DEPLOY_KEY}" \
  -H "Content-Type: application/json" \
  --data-binary @kora-ai-observability.json \
  "${REGISTRY_ENDPOINT}/v0/agentgateway/policies/kora-ai-observability"
```

`REGISTRY_ENDPOINT` is `http://agentregistry.agentregistry-system.svc.cluster.local:12121`
in-cluster; the admin UI at `agentgateway.tesserix.app` writes the same record.
The route-sync CronJob applies it within five minutes — writes are idempotent and
Kubernetes convergence is asynchronous.

## Cost, and when it is zero

`cost_source` says how a row was priced:

- `gateway` — agentgateway supplied `agw.ai.usage.cost.total`, which it can only
  do when a model cost catalog is configured on the Gateway's
  `AgentgatewayParameters` (`modelCatalog.sources`);
- `catalog` — priced from `ai_model_prices` at the rate in force when the request
  ran;
- `unpriced` — neither. Tokens and requests are still true; spend reads $0.

With no catalog on either gateway and no rows in `ai_model_prices`, every row is
`unpriced`. Tokens will be right and spend will be zero until one of the two is
filled in.

## CEL attributes and absent headers

`request.headers["x-foo"]` throws `No such key` when the header is not set, and
the attribute's evaluation fails with it. This is not theoretical: the kora
gateway's ext_proc `token_optimizer.*` attributes raise it on roughly a third of
live requests today. Tracing attributes derived from a header must be guarded:

```yaml
expression: '"x-kora-ai-capability" in request.headers ? request.headers["x-kora-ai-capability"] : ""'
```

The `tesserix.product` and `tesserix.gateway` attributes are constants and cannot
fail, so the product filter on the console keeps working regardless.

## Checking the pipeline

```bash
kubectl logs -n tesserix -l app.kubernetes.io/name=ai-usage-ingest --tail=20
kubectl get agentgatewaypolicy -n agentgateway-system kora-ai-observability \
  -o jsonpath='{.spec.frontend.tracing.backendRef}'
psql -c "select count(*), max(occurred_at) from ai_usage_events"
```
