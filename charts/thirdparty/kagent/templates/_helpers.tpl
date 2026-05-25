{{- define "kagent.labels" -}}
app.kubernetes.io/name: kagent
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tesseract-platform
app.kubernetes.io/component: agent-controller
{{- end -}}

{{- define "kagent.selectorLabels" -}}
app.kubernetes.io/name: kagent
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
