# AI trace pipeline — agents → OTel → Redpanda → Langfuse

Revived 2026-09-03 from the parked observability estate, narrowed to AI traces
only (australis ADR-0003 D5). Nothing else flows: no logs, no metrics, no
Kubernetes events. Everything runs on `optimized-v2` (`workload=infrastructure`).

## Path

| Hop | Component | What it does |
|---|---|---|
| 1 | `ai-agents` `agent_telemetry` | One OTLP trace per ADK run: agent root span, a generation per model call, a tool span per tool call, a point event per refusal or error. Trace and span ids derive from the run id; message content is never exported. Resource carries `service.namespace=<product>`, `service.name`, `tesserix.signal=ai`. Fail-open behind a batch queue. |
| 2 | `otel-gateway` (StatefulSet ×2, 20Gi spool each) | OTLP in on 4317/4318. `filter/ai` drops any span whose resource lacks `tesserix.signal=ai`. `k8sattributes` adds pod identity. Kafka exporter with an on-disk sending queue, `required_acks=-1`, retry forever. |
| 3 | `redpanda` (×3, RF=3, 10Gi each) | Topic `ai.traces`, 6 partitions, 7 day retention. Auto-create is off; the topics job is the only place topics are declared. |
| 4 | `otel-ingest` (Deployment ×2, one consumer group) | Kafka receiver with `message_marking.after=true`. `routing` connector sends each resource to `traces/<product>` by `service.namespace`; unknown products go to `nop` and are visible in `otelcol_exporter_sent_spans{exporter="nop"}`. One `otlphttp/<product>` exporter per route posts to `langfuse-web:3000/api/public/otel/v1/traces` with Basic `pk:sk`. |
| 5 | Langfuse v4 | One project per product. Traces filter by project, then by tag (`product`, agent name, service) or metadata (`tenant`, `run_id`, `state`, `definition_revision`). |

## Per-product keys

Each route reads `prod-<product>-langfuse-public-key` / `-secret-key` from
Secret Manager through an ExternalSecret whose template emits the base64 Basic
value. The evals-onboarding operator mirrors those pairs once its claim is
Ready (`k8s/operators/evals-onboarding/claims/<product>.yaml`); that needs the
org-scoped Langfuse key in `prod-langfuse-org-*` first. A route whose Secret is
missing still renders: the env is `optional`, Langfuse answers 401, the batch is
counted in `otelcol_exporter_send_failed_spans{exporter="otlphttp/<product>"}`
and dropped after `exporter.retry.maxElapsedTime`. Redpanda keeps the data.

Routes today: `kora`, `sre`, `devai`, `australis`, `ocr` (`charts/thirdparty/otel-ingest/values.yaml`).
Adding a product is one list entry plus its claim.

## Replay

If a product's traces were dropped while its key was missing or Langfuse was
down, seek the consumer group back once the fix is in place:

```bash
kubectl exec -n observability redpanda-0 -- rpk group seek otel-ingest --to start -X brokers=localhost:9092
```

Ingest re-reads the 7 day window; derived ids make the re-post an upsert.

## Agent wiring

`charts/apps/kora-ai-agents` and `charts/apps/sre-ai-agent` set
`AGENT_TELEMETRY_*` from their `telemetry:` values and allow egress to
`otel-gateway:4318` in `observability`. `observability` is not in the ambient
mesh, so the hop is plain OTLP/HTTP. Any HomeChef or Mark8ly service still
pointing at `otel-gateway` is accepted and dropped by the AI filter.

## Watch

```bash
kubectl get pods -n observability -l 'app.kubernetes.io/name in (otel-gateway,otel-ingest,redpanda)'
kubectl exec -n observability redpanda-0 -- rpk group describe otel-ingest -X brokers=localhost:9092
kubectl port-forward -n observability deploy/otel-ingest 8888 & curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_(sent|send_failed)_spans'
```

Sync order is unchanged: `redpanda` (wave -1) → `otel-ingest` (0) → `otel-gateway` (1).
