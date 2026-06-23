{{- define "clickhouse-otel.name" -}}
clickhouse-otel
{{- end -}}

{{- define "clickhouse-otel.labels" -}}
app.kubernetes.io/name: clickhouse-otel
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: observability
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "clickhouse-otel.selectorLabels" -}}
app.kubernetes.io/name: clickhouse-otel
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
