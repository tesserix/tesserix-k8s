{{- define "civiclens-ai-gateway.labels" -}}
app.kubernetes.io/name: civiclens-ai-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: civiclens
{{- end -}}
