{{- define "otel-cluster.name" -}}
otel-cluster
{{- end -}}

{{- define "otel-cluster.labels" -}}
app.kubernetes.io/name: otel-cluster
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: observability
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "otel-cluster.selectorLabels" -}}
app.kubernetes.io/name: otel-cluster
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
