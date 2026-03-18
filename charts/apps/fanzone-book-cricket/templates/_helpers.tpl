{{/*
Expand the name of the chart.
*/}}
{{- define "fanzone-book-cricket.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "fanzone-book-cricket.fullname" -}}
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
{{- define "fanzone-book-cricket.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fanzone-book-cricket.labels" -}}
helm.sh/chart: {{ include "fanzone-book-cricket.chart" . }}
{{ include "fanzone-book-cricket.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: fanzone-battle-ground
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fanzone-book-cricket.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fanzone-book-cricket.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: book-cricket
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fanzone-book-cricket.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fanzone-book-cricket.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
