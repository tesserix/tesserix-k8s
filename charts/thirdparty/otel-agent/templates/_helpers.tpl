{{- define "otel-agent.name" -}}
otel-agent
{{- end -}}

{{- define "otel-agent.labels" -}}
app.kubernetes.io/name: otel-agent
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: observability
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "otel-agent.selectorLabels" -}}
app.kubernetes.io/name: otel-agent
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
