{{- define "agentgateway.labels" -}}
app.kubernetes.io/name: agentgateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tesseract-platform
app.kubernetes.io/component: agent-data-plane
{{- end -}}

{{- define "agentgateway.selectorLabels" -}}
app.kubernetes.io/name: agentgateway
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
