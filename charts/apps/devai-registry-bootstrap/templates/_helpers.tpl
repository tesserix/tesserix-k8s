{{- define "devai-registry-bootstrap.labels" -}}
app.kubernetes.io/name: devai-registry-bootstrap
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: devai
app.kubernetes.io/component: registry-bootstrap
{{- end -}}
