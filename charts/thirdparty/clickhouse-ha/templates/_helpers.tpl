{{- define "clickhouse-ha.name" -}}
clickhouse
{{- end -}}

{{- define "clickhouse-ha.headless" -}}
clickhouse-headless
{{- end -}}

{{- define "clickhouse-ha.labels" -}}
app.kubernetes.io/name: clickhouse
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: observability
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "clickhouse-ha.selectorLabels" -}}
app.kubernetes.io/name: clickhouse
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
