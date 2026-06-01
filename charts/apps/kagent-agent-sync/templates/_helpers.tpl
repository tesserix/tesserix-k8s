{{- define "kagent-agent-sync.labels" -}}
app.kubernetes.io/name: kagent-agent-sync
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/component: agentic-runtime
{{- end -}}
