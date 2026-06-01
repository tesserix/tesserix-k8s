{{- define "agentgateway-route-sync.labels" -}}
app.kubernetes.io/name: agentgateway-route-sync
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/component: agentic-routing
{{- end -}}
