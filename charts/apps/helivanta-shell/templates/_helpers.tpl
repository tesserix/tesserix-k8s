{{- define "helivanta-shell.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "helivanta-shell.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s" (include "helivanta-shell.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "helivanta-shell.labels" -}}
app.kubernetes.io/name: {{ include "helivanta-shell.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: helivanta
app.kubernetes.io/component: shell
{{- end -}}

{{- define "helivanta-shell.selectorLabels" -}}
app.kubernetes.io/name: {{ include "helivanta-shell.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "helivanta-shell.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "helivanta-shell.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
