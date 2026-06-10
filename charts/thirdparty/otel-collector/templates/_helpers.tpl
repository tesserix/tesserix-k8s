{{- define "otel-collector.name" -}}
otel-collector
{{- end -}}

{{- define "otel-collector.labels" -}}
app.kubernetes.io/name: otel-collector
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: observability
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "otel-collector.selectorLabels" -}}
app.kubernetes.io/name: otel-collector
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
