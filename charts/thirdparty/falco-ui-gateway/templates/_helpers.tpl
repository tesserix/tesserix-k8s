{{/* Common labels */}}
{{- define "falco-ui-gateway.labels" -}}
app.kubernetes.io/name: falco-ui-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: tesserix
app.kubernetes.io/component: runtime-security
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels */}}
{{- define "falco-ui-gateway.selectorLabels" -}}
app.kubernetes.io/name: falco-ui-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
