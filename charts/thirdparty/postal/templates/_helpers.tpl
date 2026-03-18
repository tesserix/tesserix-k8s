{{/*
Expand the name of the chart.
*/}}
{{- define "postal.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "postal.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "postal.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "postal.labels" -}}
helm.sh/chart: {{ include "postal.chart" . }}
{{ include "postal.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "postal.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postal.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Worker selector labels
*/}}
{{- define "postal.workerSelectorLabels" -}}
app.kubernetes.io/name: {{ include "postal.name" . }}-worker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Cron selector labels
*/}}
{{- define "postal.cronSelectorLabels" -}}
app.kubernetes.io/name: {{ include "postal.name" . }}-cron
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
SMTP selector labels
*/}}
{{- define "postal.smtpSelectorLabels" -}}
app.kubernetes.io/name: {{ include "postal.name" . }}-smtp
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
