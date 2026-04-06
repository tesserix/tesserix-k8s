{{- define "nemoclaw.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nemoclaw.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: devai
{{- end }}

{{- define "nemoclaw.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "nemoclaw.secondaryFullname" -}}
{{ include "nemoclaw.fullname" . }}-qwen
{{- end }}

{{- define "nemoclaw.secondarySelectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}-qwen
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
