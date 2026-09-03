# AI trace pipeline — agents → OTel → Redpanda → Langfuse

Revived 2026-09-03 from the parked observability estate. AI traces have a
dedicated Redpanda topic and Langfuse consumer, while the same gateway carries
the general logs, traces, and metrics used by the observability UI. Stateful
components run on `optimized-v2` (`workload=infrastructure`).

## Path

| Hop | Component | What it does |
|---|---|---|
| 1 | `ai-agents` `agent_telemetry` | One OTLP trace per ADK run: agent root span, a generation per model call, a tool span per tool call, a point event per refusal or error. Trace and span ids derive from the run id; message content is never exported. Resource carries `service.namespace=<product>`, `service.name`, `tesserix.signal=ai`. Fail-open behind a batch queue. |
| 2 | `otel-gateway` (StatefulSet ×2, 20Gi spool each) | OTLP in on 4317/4318. Every signal is copied to the observability topics; a second trace pipeline uses `filter/ai` so only marked spans reach `ai.traces`. Both Kafka exporters use an on-disk queue, `required_acks=-1`, and retry forever. |
| 3 | `redpanda` (×3, RF=3, 40Gi each) | Topics `ai.traces`, `otel.logs`, `otel.traces`, and `otel.metrics`, each with 6 partitions and 7-day retention. Auto-create is off. |
| 4 | `otel-ingest` (Deployment ×2, two consumer groups) | The ClickHouse group writes all three general signals with replicated schema creation. The independent Langfuse group routes AI traces by `service.namespace`; unknown products go to `nop`. |
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
kubectl exec -n observability redpanda-0 -- rpk group seek otel-ingest-langfuse --to start -X brokers=localhost:9092
```

Ingest re-reads the 7 day window; derived ids make the re-post an upsert.

## Agent wiring

`charts/apps/kora-ai-agents` and `charts/apps/sre-ai-agent` set
`AGENT_TELEMETRY_*` from their `telemetry:` values and allow egress to
`otel-gateway:4318` in `observability`. `observability` is not in the ambient
mesh, so the hop is plain OTLP/HTTP. Any HomeChef or Mark8ly service still
pointing at `otel-gateway` remains available in ClickHouse even when it does not
carry the AI marker.

## Watch

```bash
kubectl get pods -n observability -l 'app.kubernetes.io/name in (otel-gateway,otel-ingest,redpanda)'
kubectl exec -n observability redpanda-0 -- rpk group describe otel-ingest-langfuse -X brokers=localhost:9092
kubectl port-forward -n observability deploy/otel-ingest 8888 & curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_(sent|send_failed)_spans'
```

Sync order is unchanged: `redpanda` (wave -1) → `otel-ingest` (0) → `otel-gateway` (1).
