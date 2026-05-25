{{/* Common labels for every resource in this chart. */}}
{{- define "agentregistry.labels" -}}
app.kubernetes.io/name: agentregistry
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tesseract-platform
app.kubernetes.io/component: agent-catalog
{{- end -}}

{{- define "agentregistry.selectorLabels" -}}
app.kubernetes.io/name: agentregistry
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
