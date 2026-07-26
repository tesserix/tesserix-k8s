{{- define "otel-ingest.name" -}}
otel-ingest
{{- end -}}

{{- define "otel-ingest.labels" -}}
app.kubernetes.io/name: otel-ingest
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: observability
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "otel-ingest.selectorLabels" -}}
app.kubernetes.io/name: otel-ingest
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
