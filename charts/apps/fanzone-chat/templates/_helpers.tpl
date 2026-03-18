{{- define "fanzone-chat.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fanzone-chat.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "fanzone-chat.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "fanzone-chat.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: fanzone-battle-ground
{{- end }}

{{- define "fanzone-chat.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fanzone-chat.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "fanzone-chat.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fanzone-chat.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
