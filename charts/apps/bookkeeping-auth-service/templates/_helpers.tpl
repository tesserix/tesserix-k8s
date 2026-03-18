{{- define "bookkeeping-auth-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "bookkeeping-auth-service.fullname" -}}
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

{{- define "bookkeeping-auth-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "bookkeeping-auth-service.labels" -}}
helm.sh/chart: {{ include "bookkeeping-auth-service.chart" . }}
{{ include "bookkeeping-auth-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: bookkeeping
{{- end }}

{{- define "bookkeeping-auth-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bookkeeping-auth-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "bookkeeping-auth-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "bookkeeping-auth-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
