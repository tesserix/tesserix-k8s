{{- define "otel-gateway.name" -}}
otel-gateway
{{- end -}}

{{- define "otel-gateway.labels" -}}
app.kubernetes.io/name: otel-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: observability
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "otel-gateway.selectorLabels" -}}
app.kubernetes.io/name: otel-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
