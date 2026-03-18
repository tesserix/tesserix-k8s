{{/*
Expand the name of the chart.
*/}}
{{- define "growthbook.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "growthbook.fullname" -}}
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
{{- define "growthbook.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "growthbook.labels" -}}
helm.sh/chart: {{ include "growthbook.chart" . }}
{{ include "growthbook.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tesseract-hub
app.kubernetes.io/component: feature-flags
{{- end }}

{{/*
Selector labels
*/}}
{{- define "growthbook.selectorLabels" -}}
app.kubernetes.io/name: {{ include "growthbook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "growthbook.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "growthbook.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
MongoDB connection string
*/}}
{{- define "growthbook.mongoUri" -}}
{{- if .Values.mongodb.enabled }}
{{- printf "mongodb://%s-mongodb:27017/growthbook" (include "growthbook.fullname" .) }}
{{- else }}
{{- .Values.config.mongoUri }}
{{- end }}
{{- end }}
