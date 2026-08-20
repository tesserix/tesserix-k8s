{{- define "ai-usage-ingest.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/component: ai-usage
{{- end -}}
