{{- define "roamie-ai-gateway.labels" -}}
app.kubernetes.io/name: roamie-ai-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: roamie
{{- end -}}
