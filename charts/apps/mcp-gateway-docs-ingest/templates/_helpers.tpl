{{- define "ingest.name" -}}
mcp-gateway-docs-ingest
{{- end -}}

{{- define "ingest.labels" -}}
app.kubernetes.io/name: {{ include "ingest.name" . }}
app.kubernetes.io/component: ingestion
app.kubernetes.io/part-of: support-platform
app.kubernetes.io/managed-by: helm
{{- end -}}
